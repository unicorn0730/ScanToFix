import SwiftUI
import Combine

#if os(iOS)
import ARKit
import RealityKit

final class LidarScanManager: NSObject, ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = "Move slowly around the object"
    @Published private(set) var isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private weak var arView: ARView?
    private var latestFrame: ARFrame?
    private let targetTriangleCount = 45_000.0

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
            }
            return
        }

        guard let arView else {
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.sceneReconstruction = .meshWithClassification

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        Task { @MainActor in
            progress = 0
            statusMessage = "Move slowly around the object"
        }
    }

    func stopScanning() {
        arView?.session.pause()
    }

    func finalizeScan() -> ScannedMesh? {
        guard let latestFrame else {
            return nil
        }

        let anchors = latestFrame.anchors.compactMap { $0 as? ARMeshAnchor }
        let mesh = ScannedMesh(meshAnchors: anchors)
        guard !mesh.isEmpty else {
            return nil
        }

        return mesh
    }

    private func statusMessage(for triangleCount: Int) -> String {
        switch triangleCount {
        case 0..<2_000:
            return "Move slowly around the object"
        case 2_000..<8_000:
            return "Good scan. Capture hidden angles"
        default:
            return "Coverage looks strong. Press Done"
        }
    }
}

extension LidarScanManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestFrame = frame

        let triangleCount = frame.anchors
            .compactMap { $0 as? ARMeshAnchor }
            .reduce(0) { partialResult, anchor in
                partialResult + anchor.geometry.faces.count
            }

        let nextProgress = min(1.0, Double(triangleCount) / targetTriangleCount)
        let nextMessage = statusMessage(for: triangleCount)

        Task { @MainActor in
            progress = nextProgress
            statusMessage = nextMessage
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in
            statusMessage = "Session failed: \(error.localizedDescription)"
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
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = self * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

#else

final class LidarScanManager: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = "LiDAR scanning requires iPhone Pro hardware"
    @Published private(set) var isSupported = false

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
