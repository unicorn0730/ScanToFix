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
}
