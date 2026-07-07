import Foundation
import SwiftData

final class SetlistViewModel {
    func insertSong(_ song: Song, at index: Int, to setlist: Setlist, context: ModelContext) {
        let entry = SetlistEntry(sortOrder: 0, song: song)
        entry.setlist = setlist
        insertEntry(entry, at: index, in: setlist, context: context)
    }

    func insertHeader(title: String, at index: Int, to setlist: Setlist, context: ModelContext) {
        let entry = SetlistEntry(sortOrder: 0, headerTitle: title)
        entry.setlist = setlist
        insertEntry(entry, at: index, in: setlist, context: context)
    }

    func renameHeader(_ entry: SetlistEntry, title: String, context: ModelContext) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entry.isHeader, let setlist = entry.setlist else { return }
        entry.headerTitle = trimmed
        persistSetlist(setlist, context: context)
    }

    func removeEntry(_ entry: SetlistEntry, from setlist: Setlist, context: ModelContext) {
        setlist.entries.removeAll { $0 === entry }
        normalizeSortOrder(for: setlist)
        context.delete(entry)
        persistSetlist(setlist, context: context)
    }

    func moveEntries(in setlist: Setlist, from source: IndexSet, to destination: Int, context: ModelContext) {
        var sorted = setlist.sortedEntries
        sorted.move(fromOffsets: source, toOffset: destination)
        for (index, entry) in sorted.enumerated() {
            entry.sortOrder = index
        }
        persistSetlist(setlist, context: context)
    }

    func setTransition(_ transition: SetlistTransition, for entry: SetlistEntry, context: ModelContext) {
        guard let setlist = entry.setlist else { return }
        entry.transition = transition
        persistSetlist(setlist, context: context)
    }

    private func insertEntry(_ entry: SetlistEntry, at index: Int, in setlist: Setlist, context: ModelContext) {
        setlist.entries.append(entry)

        var sorted = setlist.sortedEntries
        guard let entryIndex = sorted.firstIndex(where: { $0 === entry }) else { return }
        sorted.remove(at: entryIndex)
        let clampedIndex = min(max(0, index), sorted.count)
        sorted.insert(entry, at: clampedIndex)
        for (idx, item) in sorted.enumerated() {
            item.sortOrder = idx
        }
        persistSetlist(setlist, context: context)
    }

    private func persistSetlist(_ setlist: Setlist, context: ModelContext) {
        try? context.save()
        try? SongProjectBridge.persistShow(for: setlist, context: context)
    }

    private func normalizeSortOrder(for setlist: Setlist) {
        for (index, entry) in setlist.sortedEntries.enumerated() {
            entry.sortOrder = index
        }
    }
}
