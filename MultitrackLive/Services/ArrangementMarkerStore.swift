import Foundation

enum ArrangementMarkerStore {
    private static let fileName = "arrangement-markers.json"

    static func fileURL(for songID: UUID) -> URL {
        FileStore.songDirectory(for: songID).appendingPathComponent(fileName)
    }

    static func load(for songID: UUID) -> [ArrangementMarker] {
        let url = fileURL(for: songID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ArrangementMarker].self, from: data)) ?? []
    }

    static func save(_ markers: [ArrangementMarker], for songID: UUID) throws {
        try FileStore.ensureSongDirectory(for: songID)
        let data = try JSONEncoder().encode(markers)
        try data.write(to: fileURL(for: songID), options: .atomic)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
    }
}

extension Array where Element == ArrangementMarker {
    var sortedByTime: [ArrangementMarker] {
        sorted { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    /// Returns the timeline time where the section containing `time` ends.
    /// When `sampleRate` is provided, the result is snapped to the nearest sample boundary.
    func endOfSection(
        containing time: TimeInterval,
        timelineDuration: TimeInterval,
        sampleRate: Double? = nil
    ) -> TimeInterval {
        let sorted = sortedByTime
        guard !sorted.isEmpty else { return time }

        var sectionIndex = 0
        for (index, marker) in sorted.enumerated() {
            if marker.startSeconds <= time {
                sectionIndex = index
            } else {
                break
            }
        }

        let endTime: TimeInterval
        if sectionIndex + 1 < sorted.count {
            endTime = sorted[sectionIndex + 1].startSeconds
        } else {
            endTime = timelineDuration
        }

        guard let sampleRate, sampleRate > 0 else { return endTime }
        return AudioTimelineMath.quantize(endTime, sampleRate: sampleRate)
    }
}
