import Foundation
import SwiftData

@Model
final class Setlist {
    static let untitledName = "Untitled"

    var id: UUID
    var name: String
    var createdAt: Date
    var isDraft: Bool
    var lastOpenedAt: Date
    var showFilePath: String?

    @Relationship(deleteRule: .cascade, inverse: \SetlistEntry.setlist)
    var entries: [SetlistEntry]

    init(name: String, isDraft: Bool = false) {
        id = UUID()
        self.name = name
        self.isDraft = isDraft
        createdAt = Date()
        lastOpenedAt = Date()
        showFilePath = nil
        entries = []
    }

    static func untitledDraft() -> Setlist {
        Setlist(name: untitledName, isDraft: true)
    }

    var sortedEntries: [SetlistEntry] {
        entries.sorted { $0.sortOrder < $1.sortOrder }
    }

    func playbackIndex(for entry: SetlistEntry) -> Int? {
        guard entry.song != nil else { return nil }
        var songIndex = 0
        for e in sortedEntries {
            if e === entry { return songIndex }
            if e.song != nil { songIndex += 1 }
        }
        return nil
    }

    func hasNextSong(after entry: SetlistEntry) -> Bool {
        guard let idx = sortedEntries.firstIndex(where: { $0 === entry }) else { return false }
        return sortedEntries[(idx + 1)...].contains { $0.song != nil }
    }
}
