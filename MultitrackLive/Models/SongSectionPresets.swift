import Foundation

/// Canonical song section labels used by the rename sheet and import normalization.
enum SongSectionPresets {
    static let groups: [(title: String, options: [String])] = [
        ("Song Structure", [
            "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3",
            "Pre-Chorus", "Chorus", "Post-Chorus", "Bridge",
            "Refrain", "Hook", "Outro", "Ending",
        ]),
        ("Instrumental", [
            "Instrumental", "Interlude", "Solo", "Breakdown",
            "Build", "Drop", "Break", "Turnaround", "Vamp", "Tag",
        ]),
    ]

    static var allCanonicalNames: [String] {
        groups.flatMap(\.options)
    }
}
