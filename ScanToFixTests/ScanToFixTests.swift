//
//  ScanToFixTests.swift
//  ScanToFixTests
//
//  Created by 전장우 on 2/11/26.
//

import Testing
@testable import ScanToFix
import simd
import CoreGraphics

struct ScanToFixTests {
    @Test
    func repairPatchGeneratorProducesWatertightPatch() throws {
        let sourceMesh = makeOpenBoxMesh()
        let result = try RepairPatchGenerator.generate(from: sourceMesh, version: .v1)

        #expect(!result.patchMesh.isEmpty)
        #expect(result.boundaryVertexCount >= 4)
        #expect(result.boundaryPerimeter > 0)
        #expect(isWatertight(result.patchMesh))
    }

    @Test
    func repairBoundaryCandidatesAreRankedAndCapped() {
        let sourceMesh = makeOpenBoxMesh()
        let candidates = RepairPatchGenerator.detectBoundaryCandidates(from: sourceMesh)

        #expect(!candidates.isEmpty)
        #expect(candidates.count <= 3)

        if candidates.count > 1 {
            #expect(candidates[0].score >= candidates[1].score)
            #expect(candidates[0].confidence >= candidates[1].confidence)
        }
    }

    @Test
    func repairPatchCanBeGeneratedFromExplicitCandidate() throws {
        let sourceMesh = makeOpenBoxMesh()
        let candidates = RepairPatchGenerator.detectBoundaryCandidates(from: sourceMesh)
        #expect(!candidates.isEmpty)

        guard let candidate = candidates.first else {
            return
        }

        let result = try RepairPatchGenerator.generate(from: sourceMesh, version: .v2, candidate: candidate)
        #expect(!result.patchMesh.isEmpty)
        #expect(isWatertight(result.patchMesh))
    }

    @Test
    func liveScanEstimatorNormalizesAndSmoothsRects() {
        let viewport = CGSize(width: 200, height: 100)
        let pixelRect = CGRect(x: -20, y: 20, width: 160, height: 90)
        let normalized = LiveScanEstimatorMath.normalizedRect(from: pixelRect, viewportSize: viewport)

        #expect(approxEqual(normalized.minX, 0))
        #expect(approxEqual(normalized.minY, 0.2))
        #expect(approxEqual(normalized.width, 0.7))
        #expect(approxEqual(normalized.height, 0.8))

        let previous = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let next = CGRect(x: 0.5, y: 0.3, width: 0.5, height: 0.5)
        let smoothed = LiveScanEstimatorMath.smoothRect(previous: previous, next: next, alpha: 0.25)

        #expect(approxEqual(smoothed.minX, 0.2))
        #expect(approxEqual(smoothed.minY, 0.15))
        #expect(approxEqual(smoothed.width, 0.35))
        #expect(approxEqual(smoothed.height, 0.35))
    }

    @Test
    func liveScanEstimatorStabilityAndCoverageBinningBehaveAsExpected() {
        let baseline = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let stable = LiveScanEstimatorMath.rectStability(previous: baseline, current: baseline)
        let unstable = LiveScanEstimatorMath.rectStability(
            previous: baseline,
            current: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        )

        #expect(stable > unstable)

        let object = SIMD3<Float>(0, 0, 0)
        let binFront = LiveScanEstimatorMath.coverageBinIndex(
            cameraPosition: SIMD3<Float>(0, 0.2, 1),
            objectCentroid: object
        )
        let binSide = LiveScanEstimatorMath.coverageBinIndex(
            cameraPosition: SIMD3<Float>(1, 0.2, 0),
            objectCentroid: object
        )
        let binBack = LiveScanEstimatorMath.coverageBinIndex(
            cameraPosition: SIMD3<Float>(0, 0.2, -1),
            objectCentroid: object
        )

        #expect(binFront != binSide)
        #expect(binSide != binBack)
    }

    @Test
    func liveScanEstimatorLockConfidenceReflectsSignalStrength() {
        let lowConfidence = LiveScanEstimatorMath.lockConfidence(pointCount: 30, rectStability: 0.2)
        let highConfidence = LiveScanEstimatorMath.lockConfidence(pointCount: 320, rectStability: 0.95)

        #expect(highConfidence > lowConfidence)
        #expect(highConfidence <= 1)
        #expect(lowConfidence >= 0)
    }

    @Test
    func liveScanEstimatorReadinessGateAppliesThresholds() {
        let ready = LiveScanEstimatorMath.canFinalizeScan(
            lockConfidence: 0.72,
            coverage: 0.67,
            triangleCount: 2_400,
            stableLockDuration: 1.8
        )
        #expect(ready)

        let insufficientCoverage = LiveScanEstimatorMath.canFinalizeScan(
            lockConfidence: 0.72,
            coverage: 0.40,
            triangleCount: 2_400,
            stableLockDuration: 1.8
        )
        #expect(!insufficientCoverage)

        let progress = LiveScanEstimatorMath.qualityProgress(
            coverage: 0.6,
            lockConfidence: 0.7,
            triangleDensity: 0.8
        )
        #expect(progress > 0.6)
        #expect(progress <= 1)
    }

    private func makeOpenBoxMesh() -> ScannedMesh {
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(1, 0, 1),
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(0, 1, 1),
        ]

        let faces: [SIMD3<UInt32>] = [
            SIMD3<UInt32>(0, 2, 1),
            SIMD3<UInt32>(0, 3, 2),

            SIMD3<UInt32>(0, 1, 5),
            SIMD3<UInt32>(0, 5, 4),

            SIMD3<UInt32>(1, 2, 6),
            SIMD3<UInt32>(1, 6, 5),

            SIMD3<UInt32>(2, 3, 7),
            SIMD3<UInt32>(2, 7, 6),

            SIMD3<UInt32>(3, 0, 4),
            SIMD3<UInt32>(3, 4, 7),
        ]

        return ScannedMesh(vertices: vertices, faces: faces)
    }

    private func isWatertight(_ mesh: ScannedMesh) -> Bool {
        struct EdgeKey: Hashable {
            let a: UInt32
            let b: UInt32

            init(_ x: UInt32, _ y: UInt32) {
                if x <= y {
                    a = x
                    b = y
                } else {
                    a = y
                    b = x
                }
            }
        }

        var edgeUseCount: [EdgeKey: Int] = [:]
        for face in mesh.faces {
            let edges = [(face.x, face.y), (face.y, face.z), (face.z, face.x)]
            for edge in edges {
                edgeUseCount[EdgeKey(edge.0, edge.1), default: 0] += 1
            }
        }

        return edgeUseCount.values.allSatisfy { $0 == 2 }
    }

    private func approxEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
