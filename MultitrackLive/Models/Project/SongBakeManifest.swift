import Foundation

/// Performance cache metadata stored in the song project file.
/// Baked audio files live beside the project under `Baked/` and are never
/// referenced from `AudioTrack.mediaPath`.
struct SongBakeManifest: Codable, Hashable, Sendable {
    var bakedAt: Date
    var fingerprint: String
    var groupStems: [BakedGroupStem]
    var clickStem: BakedClickStem?

    var isEmpty: Bool {
        groupStems.isEmpty && clickStem == nil
    }
}

struct BakedGroupStem: Codable, Hashable, Sendable, Identifiable {
    /// Stable virtual track ID used by the playback engine for this baked stem.
    var playbackTrackID: UUID
    /// `nil` means the ungrouped bucket.
    var groupID: UUID?
    /// Path relative to the project file directory, e.g. `Baked/groups/<uuid>.caf`.
    var relativePath: String
    var duration: TimeInterval
    var trackIDs: [UUID]

    var id: UUID { playbackTrackID }
}

struct BakedClickStem: Codable, Hashable, Sendable {
    var playbackTrackID: UUID
    var relativePath: String
    var duration: TimeInterval
}
