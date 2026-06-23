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
    var transposeSemitones: Int
    var transposeHighQuality: Bool
    var clickTrackEnabled: Bool
    var clickTrackVolume: Double
    var clickTrackSubdivision: String

    @Relationship(deleteRule: .cascade, inverse: \AudioTrack.song)
    var tracks: [AudioTrack]

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
        bpm = nil
        timeSignatureNumerator = nil
        timeSignatureDenominator = nil
        transposeSemitones = 0
        transposeHighQuality = false
        clickTrackEnabled = false
        clickTrackVolume = 1.0
        clickTrackSubdivision = ClickTrackSubdivision.quarter.rawValue
        tracks = []
    }

    var clickSubdivision: ClickTrackSubdivision {
        get { ClickTrackSubdivision(rawValue: clickTrackSubdivision) ?? .quarter }
        set { clickTrackSubdivision = newValue.rawValue }
    }

    /// Stable virtual track ID for the generated click stem (never stored as `AudioTrack`).
    var clickTrackID: UUID {
        var bytes = id.uuid
        bytes.7 = 0xCC
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
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
