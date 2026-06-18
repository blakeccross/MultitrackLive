import Foundation
import SwiftData

enum TrackGroupStore {
    static let defaultNames = [
        "Drums",
        "Percussion",
        "Bass",
        "Synth",
        "EG",
        "AG",
        "BGV",
        "LV",
        "Keys",
        "Other",
    ]

    static func ensureDefaults(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<TrackGroup>())) ?? []
        guard existing.isEmpty else { return }

        for (index, name) in defaultNames.enumerated() {
            context.insert(TrackGroup(name: name, sortOrder: index))
        }
        try? context.save()
    }

    static func sortedGroups(from context: ModelContext) -> [TrackGroup] {
        var descriptor = FetchDescriptor<TrackGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func isNameAvailable(
        _ name: String,
        excluding groupID: UUID?,
        in context: ModelContext
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let groups = (try? context.fetch(FetchDescriptor<TrackGroup>())) ?? []
        return !groups.contains { group in
            group.id != groupID
                && group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    static func addGroup(named name: String, in context: ModelContext) -> TrackGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNameAvailable(trimmed, excluding: nil, in: context) else { return nil }

        let groups = sortedGroups(from: context)
        let nextSortOrder = (groups.map(\.sortOrder).max() ?? -1) + 1
        let group = TrackGroup(name: trimmed, sortOrder: nextSortOrder)
        context.insert(group)
        try? context.save()
        return group
    }

    static func delete(_ group: TrackGroup, in context: ModelContext) {
        let groupID = group.id
        let tracks = (try? context.fetch(FetchDescriptor<AudioTrack>())) ?? []
        for track in tracks where track.group?.id == groupID {
            track.group = nil
        }
        context.delete(group)
        try? context.save()
    }

    static func guessGroup(for trackName: String, from groups: [TrackGroup]) -> TrackGroup? {
        let normalized = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let tokens = tokenize(normalized)
        let candidates = groups.sorted {
            if $0.name.count != $1.name.count {
                return $0.name.count > $1.name.count
            }
            return $0.sortOrder < $1.sortOrder
        }

        for group in candidates {
            let groupName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty else { continue }

            if matches(term: groupName, in: normalized, tokens: tokens) {
                return group
            }
        }

        let aliases = keywordAliases.sorted { $0.keyword.count > $1.keyword.count }
        for alias in aliases {
            guard matches(term: alias.keyword, in: normalized, tokens: tokens) else { continue }
            if let group = groups.first(where: {
                $0.name.caseInsensitiveCompare(alias.groupName) == .orderedSame
            }) {
                return group
            }
        }

        return nil
    }

    @discardableResult
    static func autoAssignGroups(
        for song: Song,
        in context: ModelContext
    ) -> Int {
        ensureDefaults(in: context)
        let groups = sortedGroups(from: context)
        return autoAssignGroups(for: song.sortedTracks, groups: groups, in: context)
    }

    @discardableResult
    static func autoAssignGroups(
        for tracks: [AudioTrack],
        groups: [TrackGroup],
        in context: ModelContext
    ) -> Int {
        var assignedCount = 0

        for track in tracks {
            guard let group = guessGroup(for: track.displayName, from: groups) else { continue }
            track.group = group
            assignedCount += 1
        }

        if assignedCount > 0 {
            try? context.save()
        }

        return assignedCount
    }

    private static let keywordAliases: [(keyword: String, groupName: String)] = [
        // Percussion
        ("cymbals", "Percussion"),
        ("cymbal", "Percussion"),
        ("crash", "Percussion"),
        ("ride", "Percussion"),
        ("shaker", "Percussion"),
        ("tambourine", "Percussion"),
        ("conga", "Percussion"),
        ("bongo", "Percussion"),
        ("maraca", "Percussion"),
        ("cowbell", "Percussion"),
        ("clap", "Percussion"),
        ("hi-hat", "Percussion"),
        ("hihat", "Percussion"),
        // Keys
        ("piano", "Keys"),
        ("organ", "Keys"),
        ("rhodes", "Keys"),
        ("wurli", "Keys"),
        ("keyboard", "Keys"),
        // BGV
        ("vocoder", "BGV"),
        ("backing", "BGV"),
        ("harmony", "BGV"),
        ("choir", "BGV"),
        // AG
        ("acoustic", "AG"),
    ]

    private static func tokenize(_ name: String) -> [String] {
        name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private static func matches(term: String, in trackName: String, tokens: [String]) -> Bool {
        let termLower = term.lowercased()
        if tokens.contains(termLower) {
            return true
        }

        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: termLower))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }

        let range = NSRange(trackName.startIndex..., in: trackName)
        return regex.firstMatch(in: trackName, options: [], range: range) != nil
    }
}
