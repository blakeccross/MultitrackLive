import Foundation
import Observation
import SwiftData

@Observable
final class SongEditorViewModel {
    private let audioEngine = AudioEngineManager.shared

    let song: Song
    private(set) var loadError: String?
    private(set) var isLoaded = false
    private var trackDurations: [UUID: TimeInterval] = [:]

    init(song: Song) {
        self.song = song
    }

    func loadSong() {
        do {
            trackDurations = [:]
            let trackPayload = song.sortedTracks.map { track in
                let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
                let duration = FileStore.fileDuration(at: url) ?? 0
                trackDurations[track.id] = duration
                return (
                    id: track.id,
                    url: url,
                    settings: AudioEngineManager.TrackSettings(track: track)
                )
            }

            guard !trackPayload.isEmpty else {
                isLoaded = false
                loadError = "Import at least one track to preview this song."
                return
            }

            try audioEngine.loadTracks(trackPayload)
            isLoaded = true
            loadError = nil
        } catch {
            isLoaded = false
            loadError = error.localizedDescription
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
