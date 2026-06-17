import Foundation
import Observation
import SwiftData

@Observable
final class SongEditorViewModel {
    private let audioEngine = AudioEngineManager.shared

    let song: Song
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private(set) var isReloadingSong = false
    private var trackDurations: [UUID: TimeInterval] = [:]
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
            audioEngine.stop()
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

        let bakePitchShift = song.transposeHighQuality

        let preparationResult: Result<[AudioEngineManager.PreparedTrackPayload], Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    let inputs = trackInputs
                    return try await withThrowingTaskGroup(
                        of: (Int, AudioEngineManager.PreparedTrackPayload).self
                    ) { group in
                        for (index, input) in inputs.enumerated() {
                            group.addTask {
                                try Task.checkCancellation()
                                let payload = try autoreleasepool {
                                    try AudioEngineManager.prepareTrackPayload(
                                        id: input.id,
                                        url: input.url,
                                        settings: input.settings,
                                        groupID: input.groupID,
                                        bakePitchShift: bakePitchShift
                                    )
                                }
                                return (index, payload)
                            }
                        }

                        var prepared = [AudioEngineManager.PreparedTrackPayload?](
                            repeating: nil,
                            count: inputs.count
                        )
                        for try await (index, payload) in group {
                            prepared[index] = payload
                        }

                        guard prepared.allSatisfy({ $0 != nil }) else {
                            throw CancellationError()
                        }

                        return .success(prepared.map { $0! })
                    }
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
                syncTempoMap(TempoStore.loadOrMigrate(for: song))
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

    func syncTempoMap(_ tempoChanges: [TempoChange]) {
        guard isLoaded else { return }
        let normalized = tempoChanges.normalizedEnsuringInitialMarker(
            defaultBPM: song.bpm ?? TempoChange.defaultBPM
        )
        audioEngine.setTempoMap(
            normalized,
            referenceBPM: normalized.referenceBPM,
            numerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
            denominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
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
}
