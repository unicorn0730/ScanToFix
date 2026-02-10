import Foundation

struct RepairPatchProfile {
    let insertionDepth: Float
    let overlapWidth: Float
    let insertionClearance: Float
    let minimumBoundaryVertices: Int
}

enum RepairVersion: String, CaseIterable, Identifiable {
    case v1 = "V1"
    case v2 = "V2"
    case v3 = "V3"
    case v4 = "V4"

    var id: String { rawValue }

    var note: String {
        switch self {
        case .v1:
            return "Balanced fit with a light overlap rim."
        case .v2:
            return "Deeper insertion and wider overlap for durability."
        case .v3:
            return "Quick print with minimal material and shallow depth."
        case .v4:
            return "Tighter fit with small clearance and fine overlap."
        }
    }

    var exportSuffix: String {
        rawValue.lowercased()
    }

    var patchProfile: RepairPatchProfile {
        switch self {
        case .v1:
            return RepairPatchProfile(
                insertionDepth: 0.007,
                overlapWidth: 0.0015,
                insertionClearance: 0.0005,
                minimumBoundaryVertices: 4
            )
        case .v2:
            return RepairPatchProfile(
                insertionDepth: 0.010,
                overlapWidth: 0.0025,
                insertionClearance: 0.0004,
                minimumBoundaryVertices: 4
            )
        case .v3:
            return RepairPatchProfile(
                insertionDepth: 0.0045,
                overlapWidth: 0.0010,
                insertionClearance: 0.0008,
                minimumBoundaryVertices: 4
            )
        case .v4:
            return RepairPatchProfile(
                insertionDepth: 0.008,
                overlapWidth: 0.0008,
                insertionClearance: 0.0002,
                minimumBoundaryVertices: 4
            )
        }
    }
}
