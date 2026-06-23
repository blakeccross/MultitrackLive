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
    private(set) var isLoadingSong = false
    private(set) var loadError: String?
    private(set) var currentWaveformSnapshot: LiveSongWaveformSnapshot?
    private(set) var nextWaveformSnapshot: LiveSongWaveformSnapshot?

    private var loadedSongID: UUID?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

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

    /// Binds this coordinator as the owner of the shared engine's finished callback.
    /// Must be called from a stable lifecycle point (not `init`), because SwiftUI
    /// constructs throwaway `@State` default instances on every view re-render,
    /// and an `init`-time assignment would let those throwaways clobber the callback.
    private func bindPlaybackFinishedHandler() {
        audioEngine.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
    }

    func configure(setlist: Setlist) {
        bindPlaybackFinishedHandler()
        applySetlistEntries(setlist.sortedEntries)
        currentIndex = 0
        loadCurrentSong()
    }

    func syncSetlist(_ setlist: Setlist) {
        let currentSongID = currentSong?.id
        applySetlistEntries(setlist.sortedEntries)

        if let currentSongID, let newIndex = songs.firstIndex(where: { $0.id == currentSongID }) {
            currentIndex = newIndex
        } else if songs.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(currentIndex, songs.count - 1)
        }

        if let song = currentSong, song.id == loadedSongID, isLoaded {
            refreshWaveformSnapshots()
            return
        }

        loadCurrentSong()
    }

    func updateTransitions(from setlist: Setlist) {
        let currentSongID = currentSong?.id
        applySetlistEntries(setlist.sortedEntries)
        if let currentSongID, let newIndex = songs.firstIndex(where: { $0.id == currentSongID }) {
            currentIndex = newIndex
        }
    }

    private func applySetlistEntries(_ entries: [SetlistEntry]) {
        var syncedSongs: [Song] = []
        var syncedTransitions: [SetlistTransition] = []
        for entry in entries {
            guard let song = entry.song else { continue }
            syncedSongs.append(song)
            syncedTransitions.append(entry.transition)
        }
        songs = syncedSongs
        transitions = syncedTransitions
    }

    private func handlePlaybackFinished() {
        guard transitionAfterCurrentSong == .continue else { return }
        advanceToNextSong(autoPlay: true)
    }

    func loadCurrentSong(autoPlay: Bool = false, preservedTime: TimeInterval? = nil) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await performLoadCurrentSong(autoPlay: autoPlay, preservedTime: preservedTime)
        }
    }

    func play() {
        guard isLoaded, !isLoadingSong else { return }
        audioEngine.play()
    }

    func pause() {
        audioEngine.pause()
    }

    func stop() {
        loadTask?.cancel()
        audioEngine.stop()
    }

    /// Reloads arrangement and waveform metadata for the already-loaded current song.
    func refreshCurrentSongState() {
        guard let song = currentSong, song.id == loadedSongID, isLoaded else { return }
        refreshWaveformSnapshots()
        applySongEngineState(for: song)
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
        loadCurrentSong(autoPlay: autoPlay)
    }

    func applyOutputRouting() {
        guard routingProvider != nil else { return }
        let wasPlaying = audioEngine.isPlaying
        let preservedTime = audioEngine.currentTime
        audioEngine.cancelScheduledTransition()
        audioEngine.pause()
        loadCurrentSong(autoPlay: wasPlaying, preservedTime: preservedTime)
    }

    @MainActor
    private func performLoadCurrentSong(autoPlay: Bool, preservedTime: TimeInterval?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingSong = true
        defer {
            if generation == loadGeneration {
                isLoadingSong = false
                loadTask = nil
            }
        }

        guard let song = currentSong else {
            isLoaded = false
            loadedSongID = nil
            currentWaveformSnapshot = nil
            nextWaveformSnapshot = nil
            loadError = songs.isEmpty ? "Setlist has no songs." : nil
            return
        }

        if song.id != loadedSongID {
            isLoaded = false
            currentWaveformSnapshot = nil
        }

        audioEngine.stop()

        let trackInputs = SongTrackLoader.trackInputs(for: song)

        let preparationResult: Result<[AudioEngineManager.PreparedTrackPayload], Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        try SongTrackLoader.streamingPayloads(trackInputs: trackInputs)
                    )
                } catch {
                    return .failure(error)
                }
            }.value

        guard generation == loadGeneration, !Task.isCancelled else { return }

        switch preparationResult {
        case .success(var prepared):
            do {
                let tempoChanges = TempoStore.loadOrMigrate(for: song)
                let timeSignatureChanges = TimeSignatureStore.loadOrMigrate(
                    for: song,
                    tempoChanges: tempoChanges
                )
                try SongTrackLoader.appendClickTrackIfNeeded(
                    to: &prepared,
                    song: song,
                    sourceDurationForTrack: { trackID in
                        guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
                        let url = FileStore.trackURL(songID: song.id, relativePath: track.relativeFilePath)
                        return FileStore.fileDuration(at: url) ?? 1
                    },
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )

                let routing = routingProvider?()
                try audioEngine.loadPreparedTracks(prepared, routing: routing)
                applySongEngineState(for: song)
                currentWaveformSnapshot = Self.makeWaveformSnapshot(for: song)
                nextWaveformSnapshot = nextSong.flatMap { Self.makeWaveformSnapshot(for: $0) }
                loadedSongID = song.id
                isLoaded = true
                loadError = nil

                if let preservedTime {
                    audioEngine.seek(to: preservedTime)
                }
                if autoPlay {
                    audioEngine.play()
                }
            } catch {
                loadedSongID = nil
                currentWaveformSnapshot = nil
                nextWaveformSnapshot = nil
                isLoaded = false
                loadError = error.localizedDescription
            }

        case .failure(let error):
            if error is CancellationError {
                loadError = nil
            } else {
                loadedSongID = nil
                currentWaveformSnapshot = nil
                nextWaveformSnapshot = nil
                isLoaded = false
                loadError = error.localizedDescription
            }
        }
    }

    private func refreshWaveformSnapshots() {
        guard let song = currentSong else {
            currentWaveformSnapshot = nil
            nextWaveformSnapshot = nil
            return
        }
        currentWaveformSnapshot = Self.makeWaveformSnapshot(for: song)
        nextWaveformSnapshot = nextSong.flatMap { Self.makeWaveformSnapshot(for: $0) }
    }

    private func applySongEngineState(for song: Song) {
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
        let layout = SongArrangementStore.playbackLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            clipGaps: arrangement.clipGaps,
            clipRegions: arrangement.clipRegions,
            tracks: song.sortedTracks.map { track in
                (
                    id: track.id,
                    trimStart: track.trimStartSeconds,
                    trimEnd: track.trimEndSeconds ?? sourceDuration(for: track.id)
                )
            },
            inputs: inputs
        )

        audioEngine.setArrangement(
            sectionsByTrack: layout.trackSections,
            masterSections: layout.rulerSections,
            removedClips: arrangement.removedClips
        )

        let tempoChanges = TempoStore.loadOrMigrate(for: song)
        let timeSignatureChanges = TimeSignatureStore.loadOrMigrate(for: song, tempoChanges: tempoChanges)
        audioEngine.setTempoMap(
            tempoChanges,
            referenceBPM: tempoChanges.referenceBPM,
            timeSignatureChanges: timeSignatureChanges
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
            clipGaps: arrangement.clipGaps,
            clipRegions: arrangement.clipRegions,
            inputs: inputs
        )

        let timelineDuration = max(
            layout.rulerSections.last?.timelineEndSeconds ?? fileDuration,
            fileDuration
        )

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
