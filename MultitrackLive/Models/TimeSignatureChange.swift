import Foundation

struct TimeSignatureChange: Codable, Identifiable, Hashable {
    let id: UUID
    let numerator: Int
    let denominator: Int
    let startSeconds: Double
    let sortOrder: Int

    init(
        id: UUID = UUID(),
        numerator: Int,
        denominator: Int,
        startSeconds: Double,
        sortOrder: Int
    ) {
        self.id = id
        self.numerator = numerator
        self.denominator = denominator
        self.startSeconds = startSeconds
        self.sortOrder = sortOrder
    }

    var displayName: String {
        "\(numerator)/\(denominator)"
    }
}

extension Array where Element == TimeSignatureChange {
    var sortedByTime: [TimeSignatureChange] {
        sorted { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    func active(at time: TimeInterval) -> TimeSignatureChange? {
        let sorted = sortedByTime
        guard !sorted.isEmpty else { return nil }
        return sorted.last(where: { $0.startSeconds <= time + 0.0001 }) ?? sorted.first
    }
}
