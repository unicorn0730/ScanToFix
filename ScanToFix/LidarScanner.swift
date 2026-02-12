import SwiftUI
import Combine

struct LiveScanOverlayState {
    var normalizedRect: CGRect
    var lockConfidence: Double
    var coverage: Double
    var distanceMeters: Double
    var triangleCount: Int
    var trackingState: LiveScanTrackingState

    static let empty = LiveScanOverlayState(
        normalizedRect: .zero,
        lockConfidence: 0,
        coverage: 0,
        distanceMeters: 0,
        triangleCount: 0,
        trackingState: .searching
    )

    var hasTrackedRect: Bool {
        normalizedRect.width > 0 && normalizedRect.height > 0 && trackingState != .searching
    }
}

enum LiveScanTrackingState {
    case searching
    case locking
    case tracking
    case ready
}

enum LiveScanEstimatorMath {
    static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    static func normalizedRect(from pixelRect: CGRect, viewportSize: CGSize) -> CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }

        let bounds = CGRect(origin: .zero, size: viewportSize)
        let clipped = pixelRect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return .zero
        }

        let normalized = CGRect(
            x: clipped.minX / viewportSize.width,
            y: clipped.minY / viewportSize.height,
            width: clipped.width / viewportSize.width,
            height: clipped.height / viewportSize.height
        )

        return CGRect(
            x: clamp01(normalized.minX),
            y: clamp01(normalized.minY),
            width: clamp01(normalized.width),
            height: clamp01(normalized.height)
        )
    }

    static func smoothRect(previous: CGRect?, next: CGRect, alpha: CGFloat) -> CGRect {
        guard let previous else {
            return next
        }

        let clampedAlpha = min(max(alpha, 0), 1)
        let invAlpha = 1 - clampedAlpha

        return CGRect(
            x: (previous.origin.x * invAlpha) + (next.origin.x * clampedAlpha),
            y: (previous.origin.y * invAlpha) + (next.origin.y * clampedAlpha),
            width: (previous.size.width * invAlpha) + (next.size.width * clampedAlpha),
            height: (previous.size.height * invAlpha) + (next.size.height * clampedAlpha)
        )
    }

    static func rectStability(previous: CGRect?, current: CGRect) -> Double {
        guard let previous else {
            return 0.35
        }

        let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
        let currentCenter = CGPoint(x: current.midX, y: current.midY)
        let centerDelta = hypot(previousCenter.x - currentCenter.x, previousCenter.y - currentCenter.y) / sqrt(2)

        let previousArea = max(0.000001, previous.width * previous.height)
        let currentArea = max(0.000001, current.width * current.height)
        let areaDelta = abs(previousArea - currentArea) / max(previousArea, currentArea)

        let instability = min(1, (centerDelta * 2.0) + (areaDelta * 0.5))
        return clamp01(1 - instability)
    }

    static func coverageBinIndex(
        cameraPosition: SIMD3<Float>,
        objectCentroid: SIMD3<Float>,
        binCount: Int = 12
    ) -> Int {
        guard binCount > 0 else {
            return 0
        }

        let azimuth = atan2(
            Double(cameraPosition.x - objectCentroid.x),
            Double(cameraPosition.z - objectCentroid.z)
        )

        let normalized = (azimuth + Double.pi) / (2 * Double.pi)
        let scaled = Int(floor(normalized * Double(binCount)))
        return min(binCount - 1, max(0, scaled))
    }

    static func lockConfidence(pointCount: Int, rectStability: Double) -> Double {
        let pointScore = clamp01(Double(pointCount) / 280.0)
        return clamp01((0.7 * pointScore) + (0.3 * clamp01(rectStability)))
    }

    static func qualityProgress(coverage: Double, lockConfidence: Double, triangleDensity: Double) -> Double {
        clamp01((0.45 * coverage) + (0.35 * lockConfidence) + (0.20 * triangleDensity))
    }

    static func canFinalizeScan(
        lockConfidence: Double,
        coverage: Double,
        triangleCount: Int,
        stableLockDuration: TimeInterval,
        requiredLockConfidence: Double = 0.60,
        requiredCoverage: Double = 0.58,
        requiredTriangleCount: Int = 1_800,
        requiredStableLockSeconds: TimeInterval = 1.5
    ) -> Bool {
        lockConfidence >= requiredLockConfidence
            && coverage >= requiredCoverage
            && triangleCount >= requiredTriangleCount
            && stableLockDuration >= requiredStableLockSeconds
    }
}

#if os(iOS)
import ARKit
import RealityKit
import UIKit

final class LidarScanManager: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var qualityProgress: Double = 0
    @Published private(set) var statusMessage = "Center object and move closer"
    @Published private(set) var isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @Published private(set) var liveOverlayState: LiveScanOverlayState = .empty
    @Published private(set) var canFinalizeScan = false

    private weak var arView: ARView?
    private var meshAnchorsByID: [UUID: ARMeshAnchor] = [:]
    private var latestFrame: ARFrame?

    private let analysisInterval: TimeInterval = 0.125
    private let clusterVoxelSize: Float = 0.02
    private let minClusterVoxelCount = 35
    private let rectSmoothingAlpha: CGFloat = 0.25
    private let requiredTriangleCount = 1_800
    private let requiredStableLockSeconds = 1.5
    private let requiredCoverage = 0.58

    private var lastAnalysisTimestamp: TimeInterval = 0
    private var previousNormalizedRect: CGRect?
    private var visitedCoverageBins = Set<Int>()
    private var lockStartTimestamp: TimeInterval?

    func connect(to arView: ARView) {
        if self.arView === arView {
            return
        }

        self.arView = arView
        arView.automaticallyConfigureSession = false
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
    }

    func startScanning() {
        guard isSupported else {
            Task { @MainActor in
                statusMessage = "LiDAR is not available on this device"
                progress = 0
                qualityProgress = 0
                canFinalizeScan = false
                liveOverlayState = .empty
            }
            return
        }

        guard let arView else {
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.sceneReconstruction = .mesh

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        meshAnchorsByID.removeAll()
        latestFrame = nil
        resetLiveAnalysisState()
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        Task { @MainActor in
            progress = 0
            qualityProgress = 0
            statusMessage = "Center object and move closer"
            canFinalizeScan = false
            liveOverlayState = .empty
        }
    }

    func stopScanning() {
        arView?.session.pause()
    }

    func finalizeScan() -> ScannedMesh? {
        let anchorsFromCallbacks = Array(meshAnchorsByID.values)
        let anchorsFromFrame = latestFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let anchors = anchorsFromCallbacks.isEmpty ? anchorsFromFrame : anchorsFromCallbacks
        let mesh = ScannedMesh(meshAnchors: anchors)
        guard !mesh.isEmpty else {
            return nil
        }

        return mesh
    }

    private func resetLiveAnalysisState() {
        lastAnalysisTimestamp = 0
        previousNormalizedRect = nil
        visitedCoverageBins.removeAll()
        lockStartTimestamp = nil
    }

    private func analyze(frame: ARFrame) {
        guard let arView else {
            return
        }

        let anchors = Array(meshAnchorsByID.values)
        let triangleCount = anchors.reduce(0) { partialResult, anchor in
            partialResult + anchor.geometry.faces.count
        }

        let cameraPosition = frame.camera.transform.translation
        let sampledPoints = sampledWorldPoints(from: anchors, cameraPosition: cameraPosition)

        guard let trackedCluster = bestCluster(from: sampledPoints, cameraPosition: cameraPosition) else {
            previousNormalizedRect = nil
            lockStartTimestamp = nil
            applyAnalysisResult(
                rect: .zero,
                lockConfidence: 0,
                coverage: Double(visitedCoverageBins.count) / 12.0,
                distanceMeters: 0,
                triangleCount: triangleCount,
                trackingState: .searching,
                timestamp: frame.timestamp
            )
            return
        }

        let viewportSize = arView.bounds.size
        let rawPixelRect = projectedPixelRect(
            points: trackedCluster.points,
            frame: frame,
            viewportSize: viewportSize,
            orientation: interfaceOrientation(for: arView)
        )

        guard let rawPixelRect else {
            previousNormalizedRect = nil
            lockStartTimestamp = nil
            applyAnalysisResult(
                rect: .zero,
                lockConfidence: 0,
                coverage: Double(visitedCoverageBins.count) / 12.0,
                distanceMeters: 0,
                triangleCount: triangleCount,
                trackingState: .searching,
                timestamp: frame.timestamp
            )
            return
        }

        let expandedRect = rawPixelRect.insetBy(dx: -10, dy: -10)
        let normalizedRawRect = LiveScanEstimatorMath.normalizedRect(from: expandedRect, viewportSize: viewportSize)
        guard normalizedRawRect.width > 0, normalizedRawRect.height > 0 else {
            previousNormalizedRect = nil
            lockStartTimestamp = nil
            applyAnalysisResult(
                rect: .zero,
                lockConfidence: 0,
                coverage: Double(visitedCoverageBins.count) / 12.0,
                distanceMeters: 0,
                triangleCount: triangleCount,
                trackingState: .searching,
                timestamp: frame.timestamp
            )
            return
        }

        let smoothedRect = LiveScanEstimatorMath.smoothRect(
            previous: previousNormalizedRect,
            next: normalizedRawRect,
            alpha: rectSmoothingAlpha
        )
        let rectStability = LiveScanEstimatorMath.rectStability(previous: previousNormalizedRect, current: smoothedRect)
        previousNormalizedRect = smoothedRect

        let lockConfidence = LiveScanEstimatorMath.lockConfidence(
            pointCount: trackedCluster.points.count,
            rectStability: rectStability
        )

        if lockConfidence >= 0.55 {
            let coverageBin = LiveScanEstimatorMath.coverageBinIndex(
                cameraPosition: cameraPosition,
                objectCentroid: trackedCluster.centroid,
                binCount: 12
            )
            visitedCoverageBins.insert(coverageBin)
        }

        let coverage = Double(visitedCoverageBins.count) / 12.0

        if lockConfidence >= 0.60 {
            if lockStartTimestamp == nil {
                lockStartTimestamp = frame.timestamp
            }
        } else {
            lockStartTimestamp = nil
        }

        let stableLockDuration = lockStartTimestamp.map { frame.timestamp - $0 } ?? 0
        let canFinalize = LiveScanEstimatorMath.canFinalizeScan(
            lockConfidence: lockConfidence,
            coverage: coverage,
            triangleCount: triangleCount,
            stableLockDuration: stableLockDuration,
            requiredCoverage: requiredCoverage,
            requiredTriangleCount: requiredTriangleCount,
            requiredStableLockSeconds: requiredStableLockSeconds
        )

        let trackingState: LiveScanTrackingState
        if canFinalize {
            trackingState = .ready
        } else if lockConfidence < 0.60 {
            trackingState = .locking
        } else {
            trackingState = .tracking
        }

        applyAnalysisResult(
            rect: smoothedRect,
            lockConfidence: lockConfidence,
            coverage: coverage,
            distanceMeters: Double(trackedCluster.distanceMeters),
            triangleCount: triangleCount,
            trackingState: trackingState,
            timestamp: frame.timestamp
        )
    }

    private func applyAnalysisResult(
        rect: CGRect,
        lockConfidence: Double,
        coverage: Double,
        distanceMeters: Double,
        triangleCount: Int,
        trackingState: LiveScanTrackingState,
        timestamp: TimeInterval
    ) {
        let triangleDensity = LiveScanEstimatorMath.clamp01(Double(triangleCount) / Double(requiredTriangleCount))
        let quality = LiveScanEstimatorMath.qualityProgress(
            coverage: coverage,
            lockConfidence: lockConfidence,
            triangleDensity: triangleDensity
        )

        let canFinalize = LiveScanEstimatorMath.canFinalizeScan(
            lockConfidence: lockConfidence,
            coverage: coverage,
            triangleCount: triangleCount,
            stableLockDuration: (lockStartTimestamp.map { timestamp - $0 }) ?? 0,
            requiredCoverage: requiredCoverage,
            requiredTriangleCount: requiredTriangleCount,
            requiredStableLockSeconds: requiredStableLockSeconds
        )

        let state = LiveScanOverlayState(
            normalizedRect: rect,
            lockConfidence: lockConfidence,
            coverage: coverage,
            distanceMeters: distanceMeters,
            triangleCount: triangleCount,
            trackingState: trackingState
        )

        let nextMessage: String
        switch trackingState {
        case .searching:
            nextMessage = "Center object and move closer"
        case .locking:
            nextMessage = "Hold steady, locking object"
        case .tracking:
            nextMessage = "Circle object to capture unseen sides"
        case .ready:
            nextMessage = "Coverage looks strong. Press Done"
        }

        Task { @MainActor in
            liveOverlayState = state
            qualityProgress = quality
            progress = quality
            statusMessage = nextMessage
            self.canFinalizeScan = canFinalize
        }
    }

    private func sampledWorldPoints(from anchors: [ARMeshAnchor], cameraPosition: SIMD3<Float>) -> [SIMD3<Float>] {
        guard !anchors.isEmpty else {
            return []
        }

        var voxels: [VoxelKey: SIMD3<Float>] = [:]
        voxels.reserveCapacity(2_048)

        for anchor in anchors {
            let geometry = anchor.geometry
            let sampleStride = max(1, geometry.vertices.count / 240)

            for vertexIndex in stride(from: 0, to: geometry.vertices.count, by: sampleStride) {
                let localVertex = geometry.vertex(at: vertexIndex)
                let worldVertex = anchor.transform.transformPoint(localVertex)
                let distance = simd_length(worldVertex - cameraPosition)
                guard distance >= 0.10, distance <= 1.20 else {
                    continue
                }

                let voxelKey = VoxelKey(point: worldVertex, voxelSize: clusterVoxelSize)
                if voxels[voxelKey] == nil {
                    voxels[voxelKey] = worldVertex
                }
            }
        }

        return Array(voxels.values)
    }

    private func bestCluster(from points: [SIMD3<Float>], cameraPosition: SIMD3<Float>) -> ClusterCandidate? {
        guard !points.isEmpty else {
            return nil
        }

        var pointByVoxel: [VoxelKey: SIMD3<Float>] = [:]
        pointByVoxel.reserveCapacity(points.count)
        for point in points {
            pointByVoxel[VoxelKey(point: point, voxelSize: clusterVoxelSize)] = point
        }

        var remaining = Set(pointByVoxel.keys)
        var candidates: [ClusterCandidate] = []

        while let seed = remaining.first {
            remaining.remove(seed)
            var queue: [VoxelKey] = [seed]
            var index = 0
            var clusterKeys: [VoxelKey] = []

            while index < queue.count {
                let voxel = queue[index]
                index += 1
                clusterKeys.append(voxel)

                for neighbor in voxel.neighbors() where remaining.contains(neighbor) {
                    remaining.remove(neighbor)
                    queue.append(neighbor)
                }
            }

            guard clusterKeys.count >= minClusterVoxelCount else {
                continue
            }

            let clusterPoints = clusterKeys.compactMap { pointByVoxel[$0] }
            guard !clusterPoints.isEmpty else {
                continue
            }

            let centroid = clusterPoints.reduce(SIMD3<Float>.zero, +) / Float(clusterPoints.count)
            let distance = simd_length(centroid - cameraPosition)
            let pointScore = LiveScanEstimatorMath.clamp01(Double(clusterPoints.count) / 280.0)
            let distanceScore = 1.0 - LiveScanEstimatorMath.clamp01(Double(distance) / 1.2)
            let score = (0.6 * pointScore) + (0.4 * distanceScore)

            candidates.append(
                ClusterCandidate(
                    points: clusterPoints,
                    centroid: centroid,
                    distanceMeters: distance,
                    score: score
                )
            )
        }

        return candidates.max { lhs, rhs in
            lhs.score < rhs.score
        }
    }

    private func projectedPixelRect(
        points: [SIMD3<Float>],
        frame: ARFrame,
        viewportSize: CGSize,
        orientation: UIInterfaceOrientation
    ) -> CGRect? {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return nil
        }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var visiblePointCount = 0

        for point in points {
            let projected = frame.camera.projectPoint(point, orientation: orientation, viewportSize: viewportSize)
            guard projected.x.isFinite, projected.y.isFinite else {
                continue
            }

            if projected.x < -viewportSize.width || projected.x > viewportSize.width * 2 {
                continue
            }
            if projected.y < -viewportSize.height || projected.y > viewportSize.height * 2 {
                continue
            }

            minX = min(minX, projected.x)
            minY = min(minY, projected.y)
            maxX = max(maxX, projected.x)
            maxY = max(maxY, projected.y)
            visiblePointCount += 1
        }

        guard visiblePointCount >= 12,
              minX.isFinite,
              minY.isFinite,
              maxX.isFinite,
              maxY.isFinite,
              maxX > minX,
              maxY > minY
        else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func interfaceOrientation(for arView: ARView) -> UIInterfaceOrientation {
        arView.window?.windowScene?.interfaceOrientation ?? .portrait
    }

    private func mergeMeshAnchors(from anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else {
                continue
            }
            meshAnchorsByID[meshAnchor.identifier] = meshAnchor
        }
    }

    private func removeMeshAnchors(from anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else {
                continue
            }
            meshAnchorsByID.removeValue(forKey: meshAnchor.identifier)
        }
    }

    private struct VoxelKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(point: SIMD3<Float>, voxelSize: Float) {
            x = Int(floor(point.x / voxelSize))
            y = Int(floor(point.y / voxelSize))
            z = Int(floor(point.z / voxelSize))
        }

        init(x: Int, y: Int, z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }

        func neighbors() -> [VoxelKey] {
            [
                VoxelKey(x: x + 1, y: y, z: z),
                VoxelKey(x: x - 1, y: y, z: z),
                VoxelKey(x: x, y: y + 1, z: z),
                VoxelKey(x: x, y: y - 1, z: z),
                VoxelKey(x: x, y: y, z: z + 1),
                VoxelKey(x: x, y: y, z: z - 1)
            ]
        }
    }

    private struct ClusterCandidate {
        let points: [SIMD3<Float>]
        let centroid: SIMD3<Float>
        let distanceMeters: Float
        let score: Double
    }
}

extension LidarScanManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame

        guard frame.timestamp - lastAnalysisTimestamp >= analysisInterval else {
            return
        }

        lastAnalysisTimestamp = frame.timestamp
        analyze(frame: frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        mergeMeshAnchors(from: anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        mergeMeshAnchors(from: anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        removeMeshAnchors(from: anchors)
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in
            statusMessage = "Session failed: \(error.localizedDescription)"
            canFinalizeScan = false
        }
    }
}

struct LidarScannerView: UIViewRepresentable {
    @ObservedObject var manager: LidarScanManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        manager.connect(to: arView)
        manager.startScanning()
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        manager.connect(to: uiView)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

private extension ScannedMesh {
    init(meshAnchors: [ARMeshAnchor]) {
        var allVertices: [SIMD3<Float>] = []
        var allFaces: [SIMD3<UInt32>] = []

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let baseIndex = UInt32(allVertices.count)

            for vertexIndex in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: vertexIndex)
                let worldVertex = anchor.transform.transformPoint(localVertex)
                allVertices.append(worldVertex)
            }

            for faceIndex in 0..<geometry.faces.count {
                let face = geometry.faceIndices(at: faceIndex)
                allFaces.append(
                    SIMD3<UInt32>(
                        baseIndex + face.x,
                        baseIndex + face.y,
                        baseIndex + face.z
                    )
                )
            }
        }

        self = ScannedMesh(vertices: allVertices, faces: allFaces)
    }
}

private extension ARMeshGeometry {
    func vertex(at index: Int) -> SIMD3<Float> {
        let pointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * index))
        let floatBuffer = pointer.bindMemory(to: Float.self, capacity: 3)
        return SIMD3<Float>(floatBuffer[0], floatBuffer[1], floatBuffer[2])
    }

    func faceIndices(at index: Int) -> SIMD3<UInt32> {
        let faceStart = faces.buffer.contents().advanced(
            by: index * faces.indexCountPerPrimitive * faces.bytesPerIndex
        )

        if faces.bytesPerIndex == MemoryLayout<UInt16>.stride {
            let faceBuffer = faceStart.bindMemory(to: UInt16.self, capacity: 3)
            return SIMD3<UInt32>(UInt32(faceBuffer[0]), UInt32(faceBuffer[1]), UInt32(faceBuffer[2]))
        }

        let faceBuffer = faceStart.bindMemory(to: UInt32.self, capacity: 3)
        return SIMD3<UInt32>(faceBuffer[0], faceBuffer[1], faceBuffer[2])
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = self * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

#else

final class LidarScanManager: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var qualityProgress: Double = 0
    @Published private(set) var statusMessage = "LiDAR scanning requires iPhone Pro hardware"
    @Published private(set) var isSupported = false
    @Published private(set) var liveOverlayState: LiveScanOverlayState = .empty
    @Published private(set) var canFinalizeScan = false

    func startScanning() {}

    func stopScanning() {}

    func finalizeScan() -> ScannedMesh? {
        nil
    }
}

struct LidarScannerView: View {
    @ObservedObject var manager: LidarScanManager

    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: "camera.metering.matrix")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 90)
                    .foregroundStyle(.white.opacity(0.7))
            }
    }
}

#endif
