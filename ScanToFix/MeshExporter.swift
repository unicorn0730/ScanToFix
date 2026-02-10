import Foundation
import UniformTypeIdentifiers
import simd
import SwiftUI
import SceneKit

enum MeshExportFormat {
    case usdz
    case stl

    var fileExtension: String {
        switch self {
        case .usdz:
            return "usdz"
        case .stl:
            return "stl"
        }
    }

    var contentType: UTType {
        switch self {
        case .usdz:
            return .usdz
        case .stl:
            return .stlMesh
        }
    }
}

struct MeshExportPackage {
    let data: Data
    let temporaryURL: URL
    let fileName: String
}

enum MeshExportError: LocalizedError {
    case emptyMesh
    case usdzBuildFailed

    var errorDescription: String? {
        switch self {
        case .emptyMesh:
            return "The scanned mesh is empty."
        case .usdzBuildFailed:
            return "Could not generate a USDZ file from this scan."
        }
    }
}

enum MeshExporter {
    static func makePackage(from mesh: ScannedMesh, version: RepairVersion, format: MeshExportFormat) throws -> MeshExportPackage {
        guard !mesh.isEmpty else {
            throw MeshExportError.emptyMesh
        }

        let data: Data
        switch format {
        case .usdz:
            data = try makeUSDZData(from: mesh)
        case .stl:
            data = makeSTLData(from: mesh)
        }

        let baseName = "ScanToFix_\(version.exportSuffix)_\(Int(Date().timeIntervalSince1970))"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(format.fileExtension)

        try data.write(to: url, options: .atomic)

        return MeshExportPackage(data: data, temporaryURL: url, fileName: baseName)
    }

    private static func makeSTLData(from mesh: ScannedMesh) -> Data {
        var output = "solid scan_to_fix\n"

        for triangle in mesh.faces {
            let v0 = mesh.vertices[Int(triangle.x)]
            let v1 = mesh.vertices[Int(triangle.y)]
            let v2 = mesh.vertices[Int(triangle.z)]

            let edgeA = v1 - v0
            let edgeB = v2 - v0
            let crossProduct = simd_cross(edgeA, edgeB)
            let normalLength = simd_length(crossProduct)
            let normal = normalLength > 0 ? crossProduct / normalLength : SIMD3<Float>(0, 0, 0)

            output += "facet normal \(normal.x) \(normal.y) \(normal.z)\n"
            output += "  outer loop\n"
            output += "    vertex \(v0.x) \(v0.y) \(v0.z)\n"
            output += "    vertex \(v1.x) \(v1.y) \(v1.z)\n"
            output += "    vertex \(v2.x) \(v2.y) \(v2.z)\n"
            output += "  endloop\n"
            output += "endfacet\n"
        }

        output += "endsolid scan_to_fix\n"
        return Data(output.utf8)
    }

    private static func makeUSDZData(from mesh: ScannedMesh) throws -> Data {
        let scene = SCNScene()

        let scnVertices = mesh.vertices.map { vertex in
            SCNVector3(vertex.x, vertex.y, vertex.z)
        }
        let source = SCNGeometrySource(vertices: scnVertices)
        let indexData = mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.faceCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = SCNMaterial()

        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("usdz")

        scene.write(to: tempURL, options: nil, delegate: nil, progressHandler: nil)

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw MeshExportError.usdzBuildFailed
        }

        return try Data(contentsOf: tempURL)
    }
}

struct MeshFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.stlMesh, .usdz, .data]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static let stlMesh = UTType(exportedAs: "com.scantofix.mesh.stl")
}
