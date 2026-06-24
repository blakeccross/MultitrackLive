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

                        if bakePitchShift,
                           semitones != 0,
                           !input.settings.excludeFromTranspose,
                           let bakedBuffer = prepared.buffer as? DecodedStemBuffer {
                            bakeCache.store(
                                trackID: input.id,
                                relativePath: input.relativePath,
                                sourceModificationDate: modificationDate,
                                semitones: semitones,
                                buffer: bakedBuffer
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

    /// Builds payloads that stream their audio from disk on demand instead of
    /// decoding the entire stem into memory. This is cheap (it only opens each
    /// file and reads its header), so songs become near-instant to load.
    ///
    /// Pitch is applied in real time by the engine's time-pitch node rather than
    /// being baked offline, so high-quality transpose isn't pre-rendered here.
    static func streamingPayloads(
        trackInputs: [TrackInput]
    ) throws -> [AudioEngineManager.PreparedTrackPayload] {
        guard !trackInputs.isEmpty else {
            throw PlaybackCoordinatorError.noTracks
        }

        return try trackInputs.map { input in
            let buffer = try StreamingStemBuffer(url: input.url)
            var settings = input.settings
            if settings.trimEnd == nil {
                settings.trimEnd = Double(buffer.frameCount) / buffer.sampleRate
            }
            return AudioEngineManager.PreparedTrackPayload(
                id: input.id,
                buffer: buffer,
                settings: settings,
                groupID: input.groupID
            )
        }
    }

    static func timelineDuration(
        for song: Song,
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval
    ) -> TimeInterval {
        let fileDuration = song.sortedTracks
            .map { sourceDurationForTrack($0.id) }
            .max() ?? 0

        let markers = ArrangementMarkerStore.load(for: song.id).sortedByTime
        let arrangement = SongArrangementStore.load(for: song.id, markers: markers)
        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: song.sortedTracks.map(\.id),
            sourceDurationForTrack: sourceDurationForTrack
        )
        let layout = SongArrangementStore.buildLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            clipGaps: arrangement.clipGaps,
            clipRegions: arrangement.clipRegions,
            inputs: inputs
        )

        return max(layout.rulerSections.last?.timelineEndSeconds ?? fileDuration, fileDuration, 1)
    }

    static func clickTrackPayload(
        for song: Song,
        duration: TimeInterval,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange]
    ) throws -> AudioEngineManager.PreparedTrackPayload? {
        guard song.clickTrackEnabled else { return nil }

        let buffer = try ClickTrackGenerator.generate(
            duration: duration,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            subdivision: song.clickSubdivision
        )

        let settings = AudioEngineManager.TrackSettings(
            volume: Float(song.clickTrackVolume),
            pan: 0,
            isMuted: false,
            isSolo: false,
            trimStart: 0,
            trimEnd: duration,
            pitchCents: 0,
            excludeFromTranspose: true,
            ignoresSolo: true,
            bypassesArrangementMapping: true
        )

        return try AudioEngineManager.prepareTrackPayload(
            id: song.clickTrackID,
            decodedBuffer: buffer,
            settings: settings,
            groupID: nil,
            bakePitchShift: false
        )
    }

    static func appendClickTrackIfNeeded(
        to prepared: inout [AudioEngineManager.PreparedTrackPayload],
        song: Song,
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange]
    ) throws {
        guard song.clickTrackEnabled else { return }

        let duration = timelineDuration(for: song, sourceDurationForTrack: sourceDurationForTrack)
        if let clickPayload = try clickTrackPayload(
            for: song,
            duration: duration,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        ) {
            prepared.append(clickPayload)
        }
    }
}
