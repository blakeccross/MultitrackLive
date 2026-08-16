import Foundation
import SwiftData

/// A single named command exposed by a `MIDIDevice`. Sent as a MIDI note
/// (velocity is intentionally ignored).
struct MIDICommand: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// MIDI note number, 0-127.
    var note: Int

    init(id: UUID = UUID(), name: String, note: Int) {
        self.id = id
        self.name = name
        self.note = note
    }
}

/// A reusable MIDI device profile. Defines a physical CoreMIDI destination + channel
/// and a palette of named commands that MIDI track events can reference.
@Model
final class MIDIDevice {
    var id: UUID
    var name: String
    /// CoreMIDI destination identity (persisted by unique ID with name fallback).
    var destinationUniqueID: Int32?
    var destinationName: String?
    /// 1-16.
    var midiChannel: Int
    var commands: [MIDICommand]

    init(name: String) {
        id = UUID()
        self.name = name
        destinationUniqueID = nil
        destinationName = nil
        midiChannel = 1
        commands = []
    }

    func command(withID commandID: UUID) -> MIDICommand? {
        commands.first { $0.id == commandID }
    }
}
