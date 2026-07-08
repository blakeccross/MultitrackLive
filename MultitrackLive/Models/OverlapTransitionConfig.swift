import Foundation

struct OverlapTransitionConfig: Codable, Hashable {
    /// Seconds before the outgoing song ends when the incoming song begins.
    var startOffsetSeconds: TimeInterval

    init(startOffsetSeconds: TimeInterval = 0) {
        self.startOffsetSeconds = max(0, startOffsetSeconds)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startOffsetSeconds = max(
            0,
            try container.decodeIfPresent(TimeInterval.self, forKey: .startOffsetSeconds) ?? 0
        )
    }

    var isValid: Bool {
        startOffsetSeconds > 0
    }
}
