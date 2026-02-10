//
//  ScanToFixTests.swift
//  ScanToFixTests
//
//  Created by 전장우 on 2/11/26.
//

import Testing
@testable import ScanToFix
import simd

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
}
