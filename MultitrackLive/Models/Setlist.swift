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
    var showFileBookmarkData: Data?

    @Relationship(deleteRule: .cascade, inverse: \SetlistEntry.setlist)
    var entries: [SetlistEntry]

    init(name: String, isDraft: Bool = false) {
        id = UUID()
        self.name = name
        self.isDraft = isDraft
        createdAt = Date()
        lastOpenedAt = Date()
        showFilePath = nil
        showFileBookmarkData = nil
        entries = []
    }

    static func untitledDraft() -> Setlist {
        Setlist(name: untitledName, isDraft: true)
    }

    var sortedEntries: [SetlistEntry] {
        entries.sorted { $0.sortOrder < $1.sortOrder }
    }
}
