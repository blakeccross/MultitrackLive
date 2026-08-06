import Foundation

/// Canonical song section labels used by the rename sheet and import normalization.
enum SongSectionPresets {
    static let groups: [(title: String, options: [String])] = [
        ("Song Structure", [
            "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3", "Verse 4", "Verse 5", "Verse 6",
            "Pre-Chorus", "Pre-Chorus 1", "Pre-Chorus 2", "Pre-Chorus 3", "Pre-Chorus 4",
            "Chorus", "Chorus 1", "Chorus 2", "Chorus 3", "Chorus 4",
            "Post-Chorus", "Bridge", "Bridge 1", "Bridge 2", "Bridge 3", "Bridge 4",
            "Refrain", "Hook", "Outro", "Ending",
        ]),
        ("Instrumental", [
            "Instrumental", "Interlude", "Solo", "Breakdown",
            "Build", "Drop", "Break", "Turnaround", "Vamp", "Tag",
            "Acapella", "Exhortation", "Rap",
        ]),
    ]

    static var allCanonicalNames: [String] {
        groups.flatMap(\.options)
    }
}
