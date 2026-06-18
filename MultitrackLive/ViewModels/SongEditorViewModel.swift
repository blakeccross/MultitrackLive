import Foundation
import Observation
import SwiftData

@Observable
final class SongEditorViewModel {
    private struct CachedDecodedTrack {
        let relativePath: String
        let sourceModificationDate: Date
        let buffer: DecodedStemBuffer
    }

    private let audioEngine = AudioEngineManager.shared

    let song: Song
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private(set) var isReloadingSong = false
    private var trackDurations: [UUID: TimeInterval] = [:]
    private var decodedBufferCache: [UUID: CachedDecodedTrack] = [:]
    private let bakedBufferCache = TrackBakeCache()
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(song: Song) {
        self.song = song
    }

    func loadSong() {
        reloadSong()
    }

    func applyKeyChange(context: ModelContext, highQuality: Bool) async {
        let wasHighQuality = song.transposeHighQuality
        song.transposeHighQuality = highQuality
        try? context.save()

        if highQuality || wasHighQuality {
            reloadTask?.cancel()
            await performReload()
            return
        }

        applyRealtimePitch()
    }

    private func applyRealtimePitch() {
        guard isLoaded else { return }

        for track in song.sortedTracks {
            audioEngine.updateTrackSettings(
                id: track.id,
                settings: AudioEngineManager.TrackSettings(track: track)
            )
        }
    }

    private func reloadSong() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            await performReload()
        }
    }

    @MainActor
    private func performReload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isReloadingSong = true
        defer {
            if generation == reloadGeneration {
                isReloadingSong = false
                reloadTask = nil
            }
        }

        let trackInputs = song.sortedTracks.map { track in
            (
                id: track.id,
                url: FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath),
                relativePath: track.relativeFilePath,
                settings: AudioEngineManager.TrackSettings(track: track),
                groupID: track.group?.id
            )
        }

        guard !trackInputs.isEmpty else {
            isLoaded = false
            loadError = "Import at least one track to preview this song."
            return
        }

        audioEngine.stop()
        pruneDecodedBufferCache()
        bakedBufferCache.prune(activeTrackIDs: Set(trackInputs.map(\.id)))

        let sourceModificationDates = Dictionary(
            uniqueKeysWithValues: trackInputs.map { input in
                (input.id, sourceModificationDate(for: input.url))
            }
        )

        let decodedBuffers: [UUID: DecodedStemBuffer]
        do {
            decodedBuffers = try await loadDecodedBuffers(
                for: trackInputs,
                sourceModificationDates: sourceModificationDates
            )
        } catch {
            isLoaded = false
            loadError = error.localizedDescription
            return
        }

        let bakePitchShift = song.transposeHighQuality
        let bakeCache = bakedBufferCache

        let preparationResult: Result<[AudioEngineManager.PreparedTrackPayload], Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    let inputs = trackInputs
                    let buffers = decodedBuffers
                    let modDates = sourceModificationDates
                    return .success(
                        try await Self.prepareTrackPayloadsConcurrently(
                            inputs: inputs,
                            decodedBuffers: buffers,
                            sourceModificationDates: modDates,
                            bakePitchShift: bakePitchShift,
                            bakeCache: bakeCache
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

        guard generation == reloadGeneration, !Task.isCancelled else { return }

        switch preparationResult {
        case .success(let prepared):
            trackDurations = [:]
            for payload in prepared {
                trackDurations[payload.id] = Double(payload.buffer.frameCount) / payload.buffer.sampleRate
            }

            do {
                try audioEngine.loadPreparedTracks(prepared)
                isLoaded = true
                loadError = nil
                syncTempoMap(
                    TempoStore.loadOrMigrate(for: song),
                    timeSignatureChanges: TimeSignatureStore.loadOrMigrate(
                        for: song,
                        tempoChanges: TempoStore.loadOrMigrate(for: song)
                    )
                )
            } catch {
                isLoaded = false
                loadError = error.localizedDescription
            }

        case .failure(let error):
            isLoaded = false
            if error is CancellationError {
                loadError = nil
            } else {
                loadError = error.localizedDescription
            }
        }
    }

    func play() {
        guard isLoaded else { return }
        audioEngine.play()
    }

    func pause() {
        audioEngine.pause()
    }

    func stop() {
        audioEngine.stop()
    }

    func seekAndPlay(to time: TimeInterval) {
        guard isLoaded else { return }
        let wasPlaying = audioEngine.isPlaying
        audioEngine.seek(to: time)
        if !wasPlaying {
            audioEngine.play()
        }
    }

    func scheduleSectionTransition(to markerStart: TimeInterval, at transitionTime: TimeInterval) {
        guard isLoaded else { return }
        audioEngine.scheduleTransition(to: markerStart, at: transitionTime)
    }

    func cancelScheduledSectionTransition() {
        audioEngine.cancelScheduledTransition()
    }

    func snapToScheduledSection(_ markerStart: TimeInterval) {
        audioEngine.snapToTransitionTarget(markerStart)
    }

    func updateMix(for track: AudioTrack, context: ModelContext) {
        audioEngine.updateTrackSettings(id: track.id, settings: AudioEngineManager.TrackSettings(track: track))
        audioEngine.applyAllMixSettings()
        try? context.save()
    }

    func updateTrim(for track: AudioTrack, context: ModelContext) {
        audioEngine.updateTrackSettings(id: track.id, settings: AudioEngineManager.TrackSettings(track: track))
        try? context.save()
    }

    func updateGroup(for track: AudioTrack, context: ModelContext) {
        try? context.save()
    }

    @discardableResult
    func autoAssignGroups(groups: [TrackGroup], context: ModelContext) -> Int {
        TrackGroupStore.autoAssignGroups(for: song.sortedTracks, groups: groups, in: context)
    }

    func previewTrim(for track: AudioTrack) {
        audioEngine.updateTrackSettings(id: track.id, settings: AudioEngineManager.TrackSettings(track: track))
        audioEngine.stop()
        audioEngine.play()
    }

    func fileDuration(for track: AudioTrack) -> TimeInterval {
        if let cached = trackDurations[track.id] {
            return cached
        }
        let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
        let duration = FileStore.fileDuration(at: url) ?? 0
        trackDurations[track.id] = duration
        return duration
    }

    func setArrangement(
        sectionsByTrack: [UUID: [ArrangementDisplaySection]],
        masterSections: [ArrangementDisplaySection],
        removedClips: [ArrangementRemovedClip] = []
    ) {
        guard isLoaded else { return }
        audioEngine.setArrangement(
            sectionsByTrack: sectionsByTrack,
            masterSections: masterSections,
            removedClips: removedClips
        )
    }

    func applyArrangementLayout(
        _ layout: ArrangementLayoutSnapshot,
        removedClips: [ArrangementRemovedClip]
    ) {
        guard isLoaded else { return }
        setArrangement(
            sectionsByTrack: layout.trackSections,
            masterSections: layout.rulerSections,
            removedClips: removedClips
        )
    }

    func syncTrackArrangement(
        trackID: UUID,
        markers: [ArrangementMarker],
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip]
    ) {
        guard isLoaded else { return }

        let inputs = arrangementLayoutInputs(markers: markers)
        let sections = SongArrangementStore.trackDisplaySections(
            for: trackID,
            slots: slots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            inputs: inputs
        )
        audioEngine.updateTrackArrangement(
            trackID: trackID,
            sections: sections,
            removedClips: removedClips
        )
    }

    func buildArrangementLayout(
        markers: [ArrangementMarker],
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip]
    ) -> ArrangementLayoutSnapshot {
        SongArrangementStore.buildLayoutSnapshot(
            slots: slots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            inputs: arrangementLayoutInputs(markers: markers)
        )
    }

    func syncArrangement(
        markers: [ArrangementMarker],
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip]
    ) {
        guard isLoaded else { return }
        applyArrangementLayout(
            buildArrangementLayout(
                markers: markers,
                slots: slots,
                clipTrims: clipTrims,
                removedClips: removedClips
            ),
            removedClips: removedClips
        )
    }

    func syncTempoMap(
        _ tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange]
    ) {
        guard isLoaded else { return }
        let normalizedTempo = tempoChanges.normalizedEnsuringInitialMarker(
            defaultBPM: song.bpm ?? TempoChange.defaultBPM
        )
        let normalizedSignatures = timeSignatureChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
            defaultDenominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
        )
        audioEngine.setTempoMap(
            normalizedTempo,
            referenceBPM: normalizedTempo.referenceBPM,
            timeSignatureChanges: normalizedSignatures
        )
    }

    private func arrangementLayoutInputs(markers: [ArrangementMarker]) -> ArrangementLayoutInputs {
        SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: song.sortedTracks.map(\.id),
            sourceDurationForTrack: { [self] trackID in
                guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
                return fileDuration(for: track)
            }
        )
    }

    private func pruneDecodedBufferCache() {
        let activeTrackIDs = Set(song.sortedTracks.map(\.id))
        decodedBufferCache = decodedBufferCache.filter { activeTrackIDs.contains($0.key) }
    }

    private func sourceModificationDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func loadDecodedBuffers(
        for trackInputs: [(
            id: UUID,
            url: URL,
            relativePath: String,
            settings: AudioEngineManager.TrackSettings,
            groupID: UUID?
        )],
        sourceModificationDates: [UUID: Date]
    ) async throws -> [UUID: DecodedStemBuffer] {
        let maxConcurrent = max(1, ProcessInfo.processInfo.processorCount)
        let cacheSnapshot = decodedBufferCache

        return try await withThrowingTaskGroup(of: (UUID, DecodedStemBuffer).self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < trackInputs.count else { return }
                let input = trackInputs[nextIndex]
                nextIndex += 1

                group.addTask {
                    try Task.checkCancellation()
                    let modificationDate = sourceModificationDates[input.id] ?? .distantPast
                    if let cached = cacheSnapshot[input.id],
                       cached.relativePath == input.relativePath,
                       cached.sourceModificationDate == modificationDate {
                        return (input.id, cached.buffer)
                    }

                    let buffer = try DecodedStemBuffer.decode(from: input.url)
                    return (input.id, buffer)
                }
            }

            for _ in 0..<min(maxConcurrent, trackInputs.count) {
                enqueueNext()
            }

            var buffers: [UUID: DecodedStemBuffer] = [:]
            buffers.reserveCapacity(trackInputs.count)

            while let (trackID, buffer) = try await group.next() {
                buffers[trackID] = buffer
                enqueueNext()
            }

            for input in trackInputs {
                guard let buffer = buffers[input.id] else { continue }
                let modificationDate = sourceModificationDates[input.id] ?? .distantPast
                decodedBufferCache[input.id] = CachedDecodedTrack(
                    relativePath: input.relativePath,
                    sourceModificationDate: modificationDate,
                    buffer: buffer
                )
            }

            return buffers
        }
    }

    private static func prepareTrackPayloadsConcurrently(
        inputs: [(
            id: UUID,
            url: URL,
            relativePath: String,
            settings: AudioEngineManager.TrackSettings,
            groupID: UUID?
        )],
        decodedBuffers: [UUID: DecodedStemBuffer],
        sourceModificationDates: [UUID: Date],
        bakePitchShift: Bool,
        bakeCache: TrackBakeCache
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
}
