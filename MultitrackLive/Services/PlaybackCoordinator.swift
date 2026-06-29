import Foundation
import Observation
import CoreGraphics
import SwiftData
import os

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
    private static let overlapLog = Logger(subsystem: "com.blakecross.MultitrackLive", category: "SongOverlap")

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
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedNextSong: (songID: UUID, payloads: [AudioEngineManager.PreparedTrackPayload])?
    private var isInOverlap = false
    private var overlapIncomingStartTime: TimeInterval?
    private var overlapOutgoingEndTime: TimeInterval?

    private static let overlapPrefetchBuffer: TimeInterval = 15

    var routingProvider: (() -> OutputRoutingSnapshot)?
    var groupMixProvider: (() -> GroupMixSnapshot)?

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

    var isInOverlapTransition: Bool {
        isInOverlap
    }

    var playbackDisplayTime: TimeInterval {
        if isInOverlap, let start = overlapIncomingStartTime, audioEngine.isInOverlap {
            return max(0, audioEngine.currentTime - start)
        }
        return audioEngine.currentTime
    }

    /// Binds this coordinator as the owner of the shared engine's playback callbacks.
    /// Must be called from a stable lifecycle point (not `init`), because SwiftUI
    /// constructs throwaway `@State` default instances on every view re-render,
    /// and an `init`-time assignment would let those throwaways clobber the callback.
    func bindPlaybackHandlers() {
        audioEngine.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
        audioEngine.onPlaybackTimeUpdate = { [weak self] currentTime, duration in
            Task { @MainActor in
                self?.handlePlaybackTimeUpdate(currentTime: currentTime, duration: duration)
            }
        }
    }

    func unbindPlaybackHandlers() {
        audioEngine.onPlaybackFinished = nil
        audioEngine.onPlaybackTimeUpdate = nil
    }

    private func bindPlaybackFinishedHandler() {
        bindPlaybackHandlers()
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
        Self.overlapLog.info(
            "playback finished transition=\(String(describing: self.transitionAfterCurrentSong)) isInOverlap=\(self.isInOverlap) songIndex=\(self.currentIndex)"
        )
        clearOverlapTransitionStateIfNeeded()

        switch transitionAfterCurrentSong {
        case .continue, .overlap:
            advanceToNextSong(autoPlay: true)
        case .stop, .none:
            break
        }
    }

    private func clearOverlapTransitionStateIfNeeded() {
        guard isInOverlap else { return }
        isInOverlap = false
        overlapIncomingStartTime = nil
        overlapOutgoingEndTime = nil
        clearOverlapPrefetchState()
    }

    private func handlePlaybackTimeUpdate(currentTime: TimeInterval, duration: TimeInterval) {
        startPrefetchIfNeeded(currentTime: currentTime, duration: duration)
        tryBeginOverlap(currentTime: currentTime, duration: duration)
    }

    private func clearOverlapPrefetchState() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedNextSong = nil
    }

    private func canUseOverlapTransition(for song: Song?, next: Song?) -> Bool {
        guard let song, let next else { return false }
        return !song.isClickOnly && !next.isClickOnly
    }

    private func startPrefetchIfNeeded(currentTime: TimeInterval, duration: TimeInterval) {
        guard transitionAfterCurrentSong == .overlap,
              !isInOverlap,
              !audioEngine.isInOverlap,
              let next = nextSong,
              canUseOverlapTransition(for: currentSong, next: next),
              prefetchedNextSong?.songID != next.id,
              prefetchTask == nil else { return }

        let leadTime = SetlistTransition.overlapLeadTime
        let prefetchStart = max(0, duration - leadTime - Self.overlapPrefetchBuffer)
        guard currentTime >= prefetchStart || duration <= leadTime else { return }

        let songID = next.id
        prefetchTask = Task { @MainActor in
            let payloads = await Self.preparePayloads(for: next)
            guard !Task.isCancelled else { return }
            if let payloads, prefetchedNextSong?.songID != songID {
                prefetchedNextSong = (songID: songID, payloads: payloads)
            }
            prefetchTask = nil
        }
    }

    private func tryBeginOverlap(currentTime: TimeInterval, duration: TimeInterval) {
        guard transitionAfterCurrentSong == .overlap,
              !isInOverlap,
              !audioEngine.isInOverlap,
              let next = nextSong,
              canUseOverlapTransition(for: currentSong, next: next),
              let prefetched = prefetchedNextSong,
              prefetched.songID == next.id else { return }

        let leadTime = SetlistTransition.overlapLeadTime
        let incomingStartTime = max(0, duration - leadTime)
        guard currentTime + 0.05 >= incomingStartTime else { return }

        beginOverlapTransition(
            to: next,
            payloads: prefetched.payloads,
            outgoingEndTime: duration,
            incomingStartTime: incomingStartTime
        )
    }

    private func beginOverlapTransition(
        to nextSong: Song,
        payloads: [AudioEngineManager.PreparedTrackPayload],
        outgoingEndTime: TimeInterval,
        incomingStartTime: TimeInterval
    ) {
        let layout = songEngineLayout(for: nextSong)
        let routing = routingProvider?()

        do {
            let configuration = AudioEngineManager.SongOverlapConfiguration(
                payloads: payloads,
                sectionsByTrack: layout.sectionsByTrack,
                masterSections: layout.masterSections,
                removedClips: layout.removedClips,
                tempoChanges: layout.tempoChanges,
                referenceBPM: layout.tempoChanges.referenceBPM,
                timeSignatureChanges: layout.timeSignatureChanges,
                midiEvents: layout.midiEvents,
                incomingStartTime: incomingStartTime,
                outgoingEndTime: outgoingEndTime
            )
            try audioEngine.beginSongOverlap(configuration)
            applyGroupMixFromProvider()

            overlapIncomingStartTime = incomingStartTime
            overlapOutgoingEndTime = outgoingEndTime
            isInOverlap = true
            clearOverlapPrefetchState()

            guard currentIndex < songs.count - 1 else { return }
            currentIndex += 1
            loadedSongID = nextSong.id
            refreshWaveformSnapshots()

            Self.overlapLog.info(
                "coordinator overlap began song=\(nextSong.name) index=\(self.currentIndex) incomingStart=\(incomingStartTime, format: .fixed(precision: 2))"
            )
        } catch {
            loadError = error.localizedDescription
        }
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
        clearOverlapPrefetchState()
        isInOverlap = false
        overlapIncomingStartTime = nil
        overlapOutgoingEndTime = nil
        audioEngine.cancelOverlapState()
        audioEngine.stop()
    }

    /// Reloads arrangement and waveform metadata for the already-loaded current song.
    func refreshCurrentSongState() {
        guard let song = currentSong, song.id == loadedSongID, isLoaded else { return }
        refreshWaveformSnapshots()
        applySongEngineState(for: song)
    }

    func seek(to time: TimeInterval) {
        if isInOverlap, audioEngine.isInOverlap, let start = overlapIncomingStartTime {
            audioEngine.seek(to: time + start)
        } else {
            audioEngine.seek(to: time)
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
        clearOverlapPrefetchState()
        isInOverlap = false
        overlapIncomingStartTime = nil
        overlapOutgoingEndTime = nil
        audioEngine.cancelOverlapState()
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

    func updateGroupMix(context: ModelContext) {
        guard let snapshot = groupMixProvider?() else { return }
        audioEngine.applyGroupMix(snapshot)
        try? context.save()
    }

    private func applyGroupMixFromProvider() {
        guard let snapshot = groupMixProvider?() else { return }
        audioEngine.applyGroupMix(snapshot)
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

        clearOverlapPrefetchState()
        isInOverlap = false
        overlapIncomingStartTime = nil
        overlapOutgoingEndTime = nil
        audioEngine.cancelOverlapState()
        audioEngine.stop()

        if song.isClickOnly {
            do {
                let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
                let tempoChanges = projectState.tempoChanges
                let timeSignatureChanges = projectState.timeSignatureChanges
                let routing = routingProvider?()
                try audioEngine.loadClickOnlySong(
                    trackID: song.clickTrackID,
                    settings: Self.clickOnlySettings(for: song),
                    subdivision: song.clickSubdivision,
                    isEnabled: song.clickTrackEnabled,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges,
                    routing: routing
                )
                applySongEngineState(for: song)
                applyGroupMixFromProvider()
                currentWaveformSnapshot = nil
                nextWaveformSnapshot = nextSong?.isClickOnly == true ? nil : nextSong.flatMap { Self.makeWaveformSnapshot(for: $0) }
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
            return
        }

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
                let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
                let tempoChanges = projectState.tempoChanges
                let timeSignatureChanges = projectState.timeSignatureChanges
                try SongTrackLoader.appendClickTrackIfNeeded(
                    to: &prepared,
                    song: song,
                    sourceDurationForTrack: { trackID in
                        guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
                              let url = FileStore.trackURL(for: song, track: track) else { return 1 }
                        return FileStore.fileDuration(at: url) ?? 1
                    },
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )

                let routing = routingProvider?()
                try audioEngine.loadPreparedTracks(prepared, routing: routing)
                applySongEngineState(for: song)
                configureMIDIPlayback(for: song)
                applyGroupMixFromProvider()
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

    private struct SongEngineLayout {
        let sectionsByTrack: [UUID: [ArrangementDisplaySection]]
        let masterSections: [ArrangementDisplaySection]
        let removedClips: [ArrangementRemovedClip]
        let tempoChanges: [TempoChange]
        let timeSignatureChanges: [TimeSignatureChange]
        let midiEvents: [MIDIScheduler.ScheduledEvent]
    }

    private func songEngineLayout(for song: Song) -> SongEngineLayout {
        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        let markers = projectState.markers
        let arrangement = projectState.arrangement
        let trackIDs = song.sortedTracks.map(\.id)

        func sourceDuration(for trackID: UUID) -> TimeInterval {
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
                  let url = FileStore.trackURL(for: song, track: track) else { return 1 }
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

        let events = SongProjectBridge.projectStateOrDefaults(for: song).midiEvents
        let resolvedMIDI = MIDIScheduler.scheduledEvents(events: events, tracks: song.sortedMIDITracks)

        return SongEngineLayout(
            sectionsByTrack: layout.trackSections,
            masterSections: layout.rulerSections,
            removedClips: arrangement.removedClips,
            tempoChanges: projectState.tempoChanges,
            timeSignatureChanges: projectState.timeSignatureChanges,
            midiEvents: resolvedMIDI
        )
    }

    private static func preparePayloads(for song: Song) async -> [AudioEngineManager.PreparedTrackPayload]? {
        guard !song.isClickOnly else { return nil }

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

        guard case .success(var prepared) = preparationResult else { return nil }

        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        do {
            try SongTrackLoader.appendClickTrackIfNeeded(
                to: &prepared,
                song: song,
                sourceDurationForTrack: { trackID in
                    guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
                          let url = FileStore.trackURL(for: song, track: track) else { return 1 }
                    return FileStore.fileDuration(at: url) ?? 1
                },
                tempoChanges: projectState.tempoChanges,
                timeSignatureChanges: projectState.timeSignatureChanges
            )
            return prepared
        } catch {
            return nil
        }
    }

    private func configureMIDIPlayback(for song: Song) {
        let events = SongProjectBridge.projectStateOrDefaults(for: song).midiEvents
        let resolved = MIDIScheduler.scheduledEvents(events: events, tracks: song.sortedMIDITracks)
        audioEngine.configureMIDI(events: resolved)
    }

    private func applySongEngineState(for song: Song) {
        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        let markers = projectState.markers
        let arrangement = projectState.arrangement
        let trackIDs = song.sortedTracks.map(\.id)

        func sourceDuration(for trackID: UUID) -> TimeInterval {
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
                  let url = FileStore.trackURL(for: song, track: track) else { return 1 }
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

        let tempoChanges = projectState.tempoChanges
        let timeSignatureChanges = projectState.timeSignatureChanges
        audioEngine.setTempoMap(
            tempoChanges,
            referenceBPM: tempoChanges.referenceBPM,
            timeSignatureChanges: timeSignatureChanges
        )
    }

    static func makeWaveformSnapshot(for song: Song) -> LiveSongWaveformSnapshot? {
        guard !song.isClickOnly, !song.sortedTracks.isEmpty else { return nil }

        let trackSources: [(url: URL, duration: TimeInterval)] = song.sortedTracks.compactMap { track in
            guard let url = FileStore.trackURL(for: song, track: track),
                  let duration = FileStore.fileDuration(at: url) else { return nil }
            return (url, duration)
        }
        guard !trackSources.isEmpty else { return nil }

        let fileDuration = trackSources.map(\.duration).max() ?? 0
        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        let markers = projectState.markers
        let arrangement = projectState.arrangement
        let trackIDs = song.sortedTracks.map(\.id)

        func sourceDuration(for trackID: UUID) -> TimeInterval {
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
                  let url = FileStore.trackURL(for: song, track: track) else { return 1 }
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

    private static func clickOnlySettings(for song: Song) -> AudioEngineManager.TrackSettings {
        AudioEngineManager.TrackSettings(
            volume: Float(song.clickTrackVolume),
            pan: 0,
            isMuted: false,
            isSolo: false,
            trimStart: 0,
            trimEnd: nil,
            pitchCents: 0,
            excludeFromTranspose: true,
            ignoresSolo: true,
            bypassesArrangementMapping: true
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
