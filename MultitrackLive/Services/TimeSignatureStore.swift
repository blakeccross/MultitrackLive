import Foundation

enum TimeSignatureStore {
    private static let fileName = "time-signatures.json"

    static func fileURL(for songID: UUID) -> URL {
        FileStore.songDirectory(for: songID).appendingPathComponent(fileName)
    }

    static func load(for songID: UUID) -> [TimeSignatureChange] {
        let url = fileURL(for: songID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TimeSignatureChange].self, from: data)) ?? []
    }

    static func save(_ changes: [TimeSignatureChange], for songID: UUID) throws {
        try FileStore.ensureSongDirectory(for: songID)
        let data = try JSONEncoder().encode(changes)
        try data.write(to: fileURL(for: songID), options: .atomic)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
    }
}
