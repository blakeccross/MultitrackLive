import Foundation

/// A single MIDI event placed on the master timeline for a `MIDITrack`. References
/// a command from the track's device; the command resolves to a MIDI note at playback.
struct MIDIEvent: Codable, Hashable, Identifiable {
    let id: UUID
    let trackID: UUID
    /// Position on the master playback timeline, in seconds.
    var timelineSeconds: TimeInterval
    /// References a `MIDICommand` on the track's `MIDIDevice`.
    var commandID: UUID
    /// Cached command name for display (kept in sync when edited).
    var label: String

    init(
        id: UUID = UUID(),
        trackID: UUID,
        timelineSeconds: TimeInterval,
        commandID: UUID,
        label: String = ""
    ) {
        self.id = id
        self.trackID = trackID
        self.timelineSeconds = timelineSeconds
        self.commandID = commandID
        self.label = label
    }
}

/// Container persisted to `midi-events.json` per song.
struct SongMIDIEvents: Codable {
    var events: [MIDIEvent]

    init(events: [MIDIEvent] = []) {
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([MIDIEvent].self, forKey: .events) ?? []
    }
}
