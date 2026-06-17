import Foundation

enum TempoStore {
    private static let fileName = "tempo-changes.json"

    static func fileURL(for songID: UUID) -> URL {
        FileStore.songDirectory(for: songID).appendingPathComponent(fileName)
    }

    static func load(for songID: UUID) -> [TempoChange] {
        let url = fileURL(for: songID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TempoChange].self, from: data)) ?? []
    }

    static func save(_ changes: [TempoChange], for songID: UUID) throws {
        try FileStore.ensureSongDirectory(for: songID)
        let data = try JSONEncoder().encode(changes)
        try data.write(to: fileURL(for: songID), options: .atomic)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
    }

    static func loadOrMigrate(for song: Song) -> [TempoChange] {
        let stored = load(for: song.id)
        let defaultBPM = song.bpm ?? TempoChange.defaultBPM
        let normalized = stored.normalizedEnsuringInitialMarker(defaultBPM: defaultBPM)

        if stored.isEmpty || normalized != stored.sortedByMeasure {
            try? save(normalized, for: song.id)
        }

        return normalized
    }
}
