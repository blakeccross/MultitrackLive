import Foundation

enum SongTrackLoader {
    typealias TrackInput = (
        id: UUID,
        url: URL,
        relativePath: String,
        settings: AudioEngineManager.TrackSettings,
        groupID: UUID?
    )

    struct CachedDecodedTrack {
        let relativePath: String
        let sourceModificationDate: Date
        let buffer: DecodedStemBuffer
    }

    static func trackInputs(for song: Song) -> [TrackInput] {
        song.sortedTracks.map { track in
            (
                id: track.id,
                url: FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath),
                relativePath: track.relativeFilePath,
                settings: AudioEngineManager.TrackSettings(track: track),
                groupID: track.group?.id
            )
        }
    }

    static func sourceModificationDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    static func sourceModificationDates(for inputs: [TrackInput]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, sourceModificationDate(for: $0.url)) })
    }

    static func decodeTracks(
        inputs: [TrackInput],
        sourceModificationDates: [UUID: Date],
        decodedBufferCache: [UUID: CachedDecodedTrack] = [:]
    ) async throws -> [UUID: DecodedStemBuffer] {
        let maxConcurrent = max(1, ProcessInfo.processInfo.processorCount)

        return try await withThrowingTaskGroup(of: (UUID, DecodedStemBuffer).self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < inputs.count else { return }
                let input = inputs[nextIndex]
                nextIndex += 1

                group.addTask {
                    try Task.checkCancellation()
                    let modificationDate = sourceModificationDates[input.id] ?? .distantPast
                    if let cached = decodedBufferCache[input.id],
                       cached.relativePath == input.relativePath,
                       cached.sourceModificationDate == modificationDate {
                        return (input.id, cached.buffer)
                    }

                    let buffer = try DecodedStemBuffer.decode(from: input.url)
                    return (input.id, buffer)
                }
            }

            for _ in 0..<min(maxConcurrent, inputs.count) {
                enqueueNext()
            }

            var buffers: [UUID: DecodedStemBuffer] = [:]
            buffers.reserveCapacity(inputs.count)

            while let (trackID, buffer) = try await group.next() {
                buffers[trackID] = buffer
                enqueueNext()
            }

            return buffers
        }
    }

    static func prepareTrackPayloads(
        inputs: [TrackInput],
        decodedBuffers: [UUID: DecodedStemBuffer],
        sourceModificationDates: [UUID: Date],
        bakePitchShift: Bool,
        bakeCache: TrackBakeCache = .shared
    ) async throws -> [AudioEngineManager.PreparedTrackPayload] {
        let maxConcurrent = max(1, ProcessInfo.processInfo.processorCount)

        return try await withThrowingTaskGroup(
            of: (Int, AudioEngineManager.PreparedTrackPayload).self
        ) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < inputs.count else { return }
                let index = nextIndex
                nextIndex += 1
                let input = inputs[index]

                group.addTask {
                    try Task.checkCancellation()
                    guard let decodedBuffer = decodedBuffers[input.id] else {
                        throw CancellationError()
                    }

                    let modificationDate = sourceModificationDates[input.id] ?? .distantPast
                    let semitones = Int((input.settings.pitchCents / 100).rounded())

                    let payload = try autoreleasepool {
                        if bakePitchShift,
                           semitones != 0,
                           !input.settings.excludeFromTranspose,
                           let cached = bakeCache.lookup(
                               trackID: input.id,
                               relativePath: input.relativePath,
                               sourceModificationDate: modificationDate,
                               semitones: semitones
                           ) {
                            var cachedSettings = input.settings
                            cachedSettings.pitchCents = 0
                            return try AudioEngineManager.prepareTrackPayload(
                                id: input.id,
                                decodedBuffer: cached,
                                settings: cachedSettings,
                                groupID: input.groupID,
                                bakePitchShift: false
                            )
                        }

                        let prepared = try AudioEngineManager.prepareTrackPayload(
                            id: input.id,
                            decodedBuffer: decodedBuffer,
                            settings: input.settings,
                            groupID: input.groupID,
                            bakePitchShift: bakePitchShift
                        )

                        if bakePitchShift, semitones != 0, !input.settings.excludeFromTranspose {
                            bakeCache.store(
                                trackID: input.id,
                                relativePath: input.relativePath,
                                sourceModificationDate: modificationDate,
                                semitones: semitones,
                                buffer: prepared.buffer
                            )
                        }

                        return prepared
                    }

                    return (index, payload)
                }
            }

            for _ in 0..<min(maxConcurrent, inputs.count) {
                enqueueNext()
            }

            var prepared = [AudioEngineManager.PreparedTrackPayload?](
                repeating: nil,
                count: inputs.count
            )

            while let (index, payload) = try await group.next() {
                prepared[index] = payload
                enqueueNext()
            }

            guard prepared.allSatisfy({ $0 != nil }) else {
                throw CancellationError()
            }

            return prepared.map { $0! }
        }
    }

    static func loadPreparedTracks(
        trackInputs: [TrackInput],
        bakePitchShift: Bool
    ) async throws -> [AudioEngineManager.PreparedTrackPayload] {
        guard !trackInputs.isEmpty else {
            throw PlaybackCoordinatorError.noTracks
        }

        let sourceModificationDates = sourceModificationDates(for: trackInputs)
        let decodedBuffers = try await decodeTracks(
            inputs: trackInputs,
            sourceModificationDates: sourceModificationDates
        )

        return try await prepareTrackPayloads(
            inputs: trackInputs,
            decodedBuffers: decodedBuffers,
            sourceModificationDates: sourceModificationDates,
            bakePitchShift: bakePitchShift
        )
    }
}
