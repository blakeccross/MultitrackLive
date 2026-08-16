import Foundation

enum ClickTrackSubdivision: String, CaseIterable, Identifiable, Codable {
    case quarter
    case eighth
    case sixteenth

    var id: String { rawValue }

    var subdivisionsPerBeat: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .sixteenth: 4
        }
    }

    var displayName: String {
        switch self {
        case .quarter: "Quarter"
        case .eighth: "Eighth"
        case .sixteenth: "Sixteenth"
        }
    }
}
