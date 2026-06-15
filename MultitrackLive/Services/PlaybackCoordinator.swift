import Foundation
import Observation
import CoreGraphics

struct LiveSongWaveformSnapshot: Identifiable {
    let songID: UUID
    let songName: String
    let trackSources: [(url: URL, duration: TimeInterval)]
    let fileDuration: TimeInterval
    let timelineDuration: TimeInterval
    let sections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>

    var id: UUID { songID }

    var contentWidth: CGFloat {
        TimelineLayout.contentWidth(for: timelineDuration, zoom: 1)
    }
}

@Observable
final class PlaybackCoordinator {
    private let audioEngine = AudioEngineManager.shared

    private(set) var songs: [Song] = []
    private(set) var transitions: [SetlistTransition] = []
    private(set) var currentIndex = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var currentWaveformSnapshot: LiveSongWaveformSnapshot?
    private(set) var nextWaveformSnapshot: LiveSongWaveformSnapshot?

    var routingProvider: (() -> OutputRoutingSnapshot)?

    var currentSong: Song? {
        guard songs.indices.contains(currentIndex) else { return nil }
        return songs[currentIndex]
    }

    var nextSong: Song? {
        let nextIndex = currentIndex + 1
        guard songs.indices.contains(nextIndex) else { return nil }
        return songs[nextIndex]
    }

    var previousSong: Song? {
        let previousIndex = currentIndex - 1
        guard songs.indices.contains(previousIndex) else { return nil }
        return songs[previousIndex]
    }

    var transitionAfterCurrentSong: SetlistTransition? {
        guard transitions.indices.contains(currentIndex) else { return nil }
        return transitions[currentIndex]
    }

    init() {
        audioEngine.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            let shouldAutoPlay = self.transitionAfterCurrentSong == .continue
            self.advanceToNextSong(autoPlay: shouldAutoPlay)
        }
    }

    func configure(setlist: Setlist) {
        let entries = setlist.sortedEntries
        songs = entries.compactMap(\.song)
        transitions = entries.map(\.transition)
        currentIndex = 0
        loadCurrentSong()
    }

    func syncSetlist(_ setlist: Setlist) {
        let entries = setlist.sortedEntries
        let newSongs = entries.compactMap(\.song)
        let newTransitions = entries.map(\.transition)
        let currentSongID = currentSong?.id

        songs = newSongs
        transitions = newTransitions

        if let currentSongID, let newIndex = songs.firstIndex(where: { $0.id == currentSongID }) {
            currentIndex = newIndex
        } else if songs.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(currentIndex, songs.count - 1)
        }

        loadCurrentSong()
    }

    func updateTransitions(from setlist: Setlist) {
        transitions = setlist.sortedEntries.map(\.transition)
    }

    func loadCurrentSong() {
        guard let song = currentSong else {
            isLoaded = false
            currentWaveformSnapshot = nil
            nextWaveformSnapshot = nil
            loadError = songs.isEmpty ? "Setlist has no songs." : nil
            return
        }

        do {
            try loadSong(song)
            currentWaveformSnapshot = Self.makeWaveformSnapshot(for: song)
            nextWaveformSnapshot = nextSong.flatMap { Self.makeWaveformSnapshot(for: $0) }
            isLoaded = true
            loadError = nil
        } catch {
            currentWaveformSnapshot = nil
            nextWaveformSnapshot = nil
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

    func seek(to time: TimeInterval) {
        audioEngine.seek(to: time)
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

    func goToNextSong(autoPlay: Bool = false) {
        guard currentIndex < songs.count - 1 else { return }
        currentIndex += 1
        reloadAndMaybePlay(autoPlay: autoPlay)
    }

    func goToPreviousSong(autoPlay: Bool = false) {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        reloadAndMaybePlay(autoPlay: autoPlay)
    }

    func goToSong(at index: Int, autoPlay: Bool = false) {
        guard songs.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        reloadAndMaybePlay(autoPlay: autoPlay)
    }

    private func advanceToNextSong(autoPlay: Bool) {
        guard currentIndex < songs.count - 1 else { return }
        currentIndex += 1
        reloadAndMaybePlay(autoPlay: autoPlay)
    }

    private func reloadAndMaybePlay(autoPlay: Bool) {
        audioEngine.cancelScheduledTransition()
        audioEngine.stop()
        loadCurrentSong()
        if autoPlay, isLoaded {
            audioEngine.play()
        }
    }

    func applyOutputRouting() {
        guard routingProvider != nil else { return }
        let wasPlaying = audioEngine.isPlaying
        let preservedTime = audioEngine.currentTime
        audioEngine.cancelScheduledTransition()
        audioEngine.pause()
        loadCurrentSong()
        if wasPlaying, isLoaded {
            audioEngine.seek(to: preservedTime)
            audioEngine.play()
        }
    }

    private func loadSong(_ song: Song) throws {
        let trackPayload = song.sortedTracks.map { track -> (id: UUID, url: URL, settings: AudioEngineManager.TrackSettings, groupID: UUID?) in
            let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
            return (track.id, url, AudioEngineManager.TrackSettings(track: track), track.group?.id)
        }

        guard !trackPayload.isEmpty else {
            throw PlaybackCoordinatorError.noTracks
        }

        let routing = routingProvider?()
        try audioEngine.loadTracks(trackPayload, routing: routing)

        let markers = ArrangementMarkerStore.load(for: song.id).sortedByTime
        let arrangement = SongArrangementStore.load(for: song.id, markers: markers)
        let trackIDs = song.sortedTracks.map(\.id)

        func sourceDuration(for trackID: UUID) -> TimeInterval {
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
            let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
            return FileStore.fileDuration(at: url) ?? 1
        }

        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDuration
        )
        let layout = SongArrangementStore.buildLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            inputs: inputs
        )

        audioEngine.setArrangement(
            sectionsByTrack: layout.trackSections,
            masterSections: layout.rulerSections,
            removedClips: arrangement.removedClips
        )
    }

    static func makeWaveformSnapshot(for song: Song) -> LiveSongWaveformSnapshot? {
        guard !song.sortedTracks.isEmpty else { return nil }

        let trackSources: [(url: URL, duration: TimeInterval)] = song.sortedTracks.compactMap { track in
            let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
            guard let duration = FileStore.fileDuration(at: url) else { return nil }
            return (url, duration)
        }
        guard !trackSources.isEmpty else { return nil }

        let fileDuration = trackSources.map(\.duration).max() ?? 0
        let markers = ArrangementMarkerStore.load(for: song.id).sortedByTime
        let arrangement = SongArrangementStore.load(for: song.id, markers: markers)
        let trackIDs = song.sortedTracks.map(\.id)

        func sourceDuration(for trackID: UUID) -> TimeInterval {
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
            let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
            return FileStore.fileDuration(at: url) ?? 1
        }

        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDuration
        )
        let layout = SongArrangementStore.buildLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            inputs: inputs
        )

        let timelineDuration = layout.rulerSections.last?.timelineEndSeconds ?? fileDuration

        return LiveSongWaveformSnapshot(
            songID: song.id,
            songName: song.name,
            trackSources: trackSources,
            fileDuration: fileDuration,
            timelineDuration: timelineDuration,
            sections: layout.rulerSections,
            loopSlotIDs: arrangement.loopSlotIDs
        )
    }
}

enum PlaybackCoordinatorError: LocalizedError {
    case noTracks

    var errorDescription: String? {
        switch self {
        case .noTracks:
            return "This song has no imported tracks."
        }
    }
}
