import Foundation

enum RepairVersion: String, CaseIterable, Identifiable {
    case v1 = "V1"
    case v2 = "V2"
    case v3 = "V3"
    case v4 = "V4"

    var id: String { rawValue }

    var note: String {
        switch self {
        case .v1:
            return "Balanced repair for strength and print speed."
        case .v2:
            return "Thicker lip edges for extra durability."
        case .v3:
            return "Minimal material usage for quick prototyping."
        case .v4:
            return "Highest detail for a near-original finish."
        }
    }

    var exportSuffix: String {
        rawValue.lowercased()
    }
}
