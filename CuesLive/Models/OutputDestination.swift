import Foundation

enum OutputDestination: Codable, Equatable, Hashable, Identifiable {
    case stereoPair(startChannel: Int)
    case mono(channel: Int)

    var id: String {
        switch self {
        case .stereoPair(let startChannel):
            return "stereo-\(startChannel)"
        case .mono(let channel):
            return "mono-\(channel)"
        }
    }

    var displayLabel: String {
        switch self {
        case .stereoPair(let startChannel):
            return "\(startChannel)-\(startChannel + 1)"
        case .mono(let channel):
            return "\(channel) (Mono)"
        }
    }

    static let defaultDestination: OutputDestination = .stereoPair(startChannel: 1)
}
