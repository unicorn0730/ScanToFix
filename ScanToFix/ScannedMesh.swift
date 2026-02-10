import Foundation
import simd

struct ScannedMesh {
    let vertices: [SIMD3<Float>]
    let faces: [SIMD3<UInt32>]

    var isEmpty: Bool {
        vertices.isEmpty || faces.isEmpty
    }

    var vertexCount: Int {
        vertices.count
    }

    var faceCount: Int {
        faces.count
    }

    func variant(for version: RepairVersion) -> ScannedMesh {
        switch version {
        case .v1:
            return limited(to: 30_000)
        case .v2:
            return inflated(by: 0.015).limited(to: 36_000)
        case .v3:
            return limited(to: 14_000)
        case .v4:
            return self
        }
    }

    private func limited(to maxFaceCount: Int) -> ScannedMesh {
        guard faceCount > maxFaceCount, maxFaceCount > 0 else {
            return self
        }

        let stride = max(1, faceCount / maxFaceCount)
        let reducedFaces = faces.enumerated().compactMap { index, face in
            index.isMultiple(of: stride) ? face : nil
        }
        return ScannedMesh(vertices: vertices, faces: reducedFaces)
    }

    private func inflated(by amount: Float) -> ScannedMesh {
        guard !vertices.isEmpty else {
            return self
        }

        let centroid = vertices.reduce(SIMD3<Float>.zero, +) / Float(vertices.count)
        let adjustedVertices = vertices.map { vertex in
            let direction = vertex - centroid
            return centroid + direction * (1 + amount)
        }
        return ScannedMesh(vertices: adjustedVertices, faces: faces)
    }
}
