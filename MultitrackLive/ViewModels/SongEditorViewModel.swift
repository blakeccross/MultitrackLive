import Foundation
import Observation
import SwiftData

@Observable
final class SongEditorViewModel {
    private typealias CachedDecodedTrack = SongTrackLoader.CachedDecodedTrack

    private let audioEngine = AudioEngineManager.shared

    let song: Song
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private(set) var isReloadingSong = false
    private var trackDurations: [UUID: TimeInterval] = [:]
    private var decodedBufferCache: [UUID: CachedDecodedTrack] = [:]
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

    func reloadSongForClickTrackChanges() {
        reloadSong()
    }

    func updateClickTrackMix(context: ModelContext) {
        guard song.clickTrackEnabled, isLoaded else { return }
        audioEngine.updateTrackSettings(id: song.clickTrackID, settings: clickTrackSettings())
        audioEngine.applyAllMixSettings()
        try? context.save()
    }

    private func clickTrackSettings() -> AudioEngineManager.TrackSettings {
        AudioEngineManager.TrackSettings(
            volume: Float(song.clickTrackVolume),
            pan: 0,
            isMuted: false,
            isSolo: false,
            trimStart: 0,
            trimEnd: nil,
            pitchCents: 0,
            excludeFromTranspose: true,
            ignoresSolo: true
        )
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
        TrackBakeCache.shared.prune(activeTrackIDs: Set(trackInputs.map(\.id)))

        let sourceModificationDates = SongTrackLoader.sourceModificationDates(for: trackInputs)

        let decodedBuffers: [UUID: DecodedStemBuffer]
        do {
            decodedBuffers = try await SongTrackLoader.decodeTracks(
                inputs: trackInputs,
                sourceModificationDates: sourceModificationDates,
                decodedBufferCache: decodedBufferCache
            )
            for input in trackInputs {
                guard let buffer = decodedBuffers[input.id] else { continue }
                let modificationDate = sourceModificationDates[input.id] ?? .distantPast
                decodedBufferCache[input.id] = CachedDecodedTrack(
                    relativePath: input.relativePath,
                    sourceModificationDate: modificationDate,
                    buffer: buffer
                )
            }
        } catch {
            isLoaded = false
            loadError = error.localizedDescription
            return
        }

        let bakePitchShift = song.transposeHighQuality

        let preparationResult: Result<[AudioEngineManager.PreparedTrackPayload], Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        try await SongTrackLoader.prepareTrackPayloads(
                            inputs: trackInputs,
                            decodedBuffers: decodedBuffers,
                            sourceModificationDates: sourceModificationDates,
                            bakePitchShift: bakePitchShift
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

        guard generation == reloadGeneration, !Task.isCancelled else { return }

        switch preparationResult {
        case .success(var prepared):
            trackDurations = [:]
            for payload in prepared {
                trackDurations[payload.id] = Double(payload.buffer.frameCount) / payload.buffer.sampleRate
            }

            let tempoChanges = TempoStore.loadOrMigrate(for: song)
            let timeSignatureChanges = TimeSignatureStore.loadOrMigrate(
                for: song,
                tempoChanges: tempoChanges
            )

            do {
                try SongTrackLoader.appendClickTrackIfNeeded(
                    to: &prepared,
                    song: song,
                    sourceDurationForTrack: { [self] trackID in
                        if let cached = trackDurations[trackID] {
                            return cached
                        }
                        guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
                        return fileDuration(for: track)
                    },
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )
                if let clickPayload = prepared.first(where: { $0.id == song.clickTrackID }) {
                    trackDurations[clickPayload.id] = Double(clickPayload.buffer.frameCount) / clickPayload.buffer.sampleRate
                }

                try audioEngine.loadPreparedTracks(prepared)
                isLoaded = true
                loadError = nil
                syncTempoMap(tempoChanges, timeSignatureChanges: timeSignatureChanges)
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
}
