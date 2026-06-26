import Foundation
import SwiftData

/// A MIDI track that sends commands from its associated `MIDIDevice` to external
/// gear at manually-placed points on the song timeline. Event data is stored
/// separately as a JSON sidecar (see `MIDIEventStore`).
@Model
final class MIDITrack {
    var id: UUID
    var displayName: String
    var sortOrder: Int

    var device: MIDIDevice?
    var song: Song?

    init(displayName: String, sortOrder: Int) {
        id = UUID()
        self.displayName = displayName
        self.sortOrder = sortOrder
    }
}
