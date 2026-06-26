import Foundation

/// JSON sidecar store for MIDI Program Change events, keyed by song ID.
/// Mirrors `SongArrangementStore` (per-song file in the song directory).
enum MIDIEventStore {
    private static let fileName = "midi-events.json"

    static func fileURL(for songID: UUID) -> URL {
        FileStore.songDirectory(for: songID).appendingPathComponent(fileName)
    }

    static func load(for songID: UUID) -> [MIDIEvent] {
        let url = fileURL(for: songID)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(SongMIDIEvents.self, from: data) else {
            return []
        }
        return stored.events.sorted { $0.timelineSeconds < $1.timelineSeconds }
    }

    static func save(_ events: [MIDIEvent], for songID: UUID) throws {
        try FileStore.ensureSongDirectory(for: songID)
        let data = try JSONEncoder().encode(SongMIDIEvents(events: events))
        try data.write(to: fileURL(for: songID), options: .atomic)
    }

    static func saveAsync(_ events: [MIDIEvent], for songID: UUID) {
        Task.detached(priority: .utility) {
            try? save(events, for: songID)
        }
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
    }
}
