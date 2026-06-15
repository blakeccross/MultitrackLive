import Foundation
import SwiftData

@Model
final class Setlist {
    var id: UUID
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SetlistEntry.setlist)
    var entries: [SetlistEntry]

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = Date()
        entries = []
    }

    var sortedEntries: [SetlistEntry] {
        entries.sorted { $0.sortOrder < $1.sortOrder }
    }
}
