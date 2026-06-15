import Foundation
import Observation
import SwiftData

@Observable
final class SetlistViewModel {
    func addSong(_ song: Song, to setlist: Setlist, context: ModelContext) {
        let entry = SetlistEntry(sortOrder: setlist.entries.count, song: song)
        entry.setlist = setlist
        setlist.entries.append(entry)
        try? context.save()
    }

    func removeEntry(_ entry: SetlistEntry, from setlist: Setlist, context: ModelContext) {
        setlist.entries.removeAll { $0.sortOrder == entry.sortOrder && $0.song?.id == entry.song?.id }
        normalizeSortOrder(for: setlist)
        context.delete(entry)
        try? context.save()
    }

    func moveEntries(in setlist: Setlist, from source: IndexSet, to destination: Int, context: ModelContext) {
        var sorted = setlist.sortedEntries
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in sorted.enumerated() {
            entry.sortOrder = index
        }
        try? context.save()
    }

    private func normalizeSortOrder(for setlist: Setlist) {
        for (index, entry) in setlist.sortedEntries.enumerated() {
            entry.sortOrder = index
        }
    }
}
