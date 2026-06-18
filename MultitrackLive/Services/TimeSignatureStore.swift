import Foundation

enum TimeSignatureStore {
    private static let fileName = "time-signatures.json"

    private struct StoredRecord: Decodable {
        let id: UUID
        let numerator: Int
        let denominator: Int
        let startMeasure: Int?
        let startSeconds: Double?
        let sortOrder: Int
    }

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

    static func loadOrMigrate(for song: Song, tempoChanges: [TempoChange]) -> [TimeSignatureChange] {
        let url = fileURL(for: song.id)
        guard let data = try? Data(contentsOf: url) else {
            return defaultChanges(for: song)
        }

        let records = (try? JSONDecoder().decode([StoredRecord].self, from: data)) ?? []
        guard !records.isEmpty else {
            return defaultChanges(for: song)
        }

        let defaultNumerator = song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator
        let defaultDenominator = song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
        let fallbackSignature = defaultChanges(for: song)
        let hasLegacySeconds = records.contains { $0.startMeasure == nil && $0.startSeconds != nil }

        var builtChanges: [TimeSignatureChange] = []
        let sortedRecords = records.sorted { lhs, rhs in
            let lhsPosition = lhs.startMeasure ?? Int.max
            let rhsPosition = rhs.startMeasure ?? Int.max
            if lhsPosition != rhsPosition {
                return lhsPosition < rhsPosition
            }
            let lhsSeconds = lhs.startSeconds ?? 0
            let rhsSeconds = rhs.startSeconds ?? 0
            if lhsSeconds != rhsSeconds {
                return lhsSeconds < rhsSeconds
            }
            return lhs.sortOrder < rhs.sortOrder
        }

        for record in sortedRecords {
            let measure: Int
            if let startMeasure = record.startMeasure {
                measure = startMeasure
            } else if let startSeconds = record.startSeconds {
                let activeSignatures = builtChanges.isEmpty ? fallbackSignature : builtChanges
                measure = MeasureTiming.measureIndex(
                    at: startSeconds,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: activeSignatures
                )
            } else {
                measure = 1
            }

            let change = TimeSignatureChange(
                id: record.id,
                numerator: record.numerator,
                denominator: record.denominator,
                startMeasure: measure,
                sortOrder: record.sortOrder
            )
            builtChanges = (builtChanges + [change]).normalizedEnsuringInitialMarker(
                defaultNumerator: defaultNumerator,
                defaultDenominator: defaultDenominator
            )
        }

        let normalized = builtChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: defaultNumerator,
            defaultDenominator: defaultDenominator
        )

        if hasLegacySeconds || normalized != load(for: song.id).sortedByMeasure {
            try? save(normalized, for: song.id)
        }

        return normalized
    }

    private static func defaultChanges(for song: Song) -> [TimeSignatureChange] {
        [
            TimeSignatureChange(
                numerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
                denominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator,
                startMeasure: 1,
                sortOrder: 0
            )
        ]
    }
}
