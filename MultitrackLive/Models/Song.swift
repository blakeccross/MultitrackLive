import Foundation
import SwiftData

@Model
final class Song {
    var id: UUID
    var name: String
    var createdAt: Date
    var bpm: Double?

    @Relationship(deleteRule: .cascade, inverse: \AudioTrack.song)
    var tracks: [AudioTrack]

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
        bpm = nil
        tracks = []
    }

    var sortedTracks: [AudioTrack] {
        tracks.sorted { $0.sortOrder < $1.sortOrder }
    }
}
