import Foundation
import SwiftData

@Model
final class Song {
    var id: UUID
    var name: String
    var createdAt: Date
    var bpm: Double?
    var timeSignatureNumerator: Int?
    var timeSignatureDenominator: Int?

    @Relationship(deleteRule: .cascade, inverse: \AudioTrack.song)
    var tracks: [AudioTrack]

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
        bpm = nil
        timeSignatureNumerator = nil
        timeSignatureDenominator = nil
        tracks = []
    }

    var timeSignatureDisplay: String? {
        guard let numerator = timeSignatureNumerator,
              let denominator = timeSignatureDenominator,
              numerator > 0,
              denominator > 0 else {
            return nil
        }
        return "\(numerator)/\(denominator)"
    }

    var sortedTracks: [AudioTrack] {
        tracks.sorted { $0.sortOrder < $1.sortOrder }
    }
}
