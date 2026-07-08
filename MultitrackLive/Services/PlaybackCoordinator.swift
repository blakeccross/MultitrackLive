import Foundation
import Observation
import CoreGraphics
import SwiftData

struct LiveSongWaveformSnapshot: Identifiable {
    let songID: UUID
    let songName: String
    let trackSources: [(url: URL, duration: TimeInterval)]
    let fileDuration: TimeInterval
    let timelineDuration: TimeInterval
    /// Marker columns used for section labels, cueing, and loop badges.
    let sections: [ArrangementDisplaySection]
    /// Playback clip layout used to map timeline time to source audio for the waveform.
    let peakSections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>

    var id: UUID { songID }

    var contentWidth: CGFloat {
        TimelineLayout.contentWidth(for: timelineDuration, zoom: 1)
    }
}

enum LiveSetlistTimelineItem: Identifiable {
    case header(scrollID: String, title: String)
    case song(songID: UUID, playbackIndex: Int, transitionAfter: SetlistTransition?)

    var id: String {
        switch self {
        case .header(let scrollID, _):
            scrollID
        case .song(_, let playbackIndex, _):
            "song-\(playbackIndex)"
        }
    }
}

@Observable
final class PlaybackCoordinator {
    private let audioEngine = AudioEngineManager.shared

    private(set) var songs: [Song] = []
    private(set) var transitions: [SetlistTransition] = []
    private(set) var overlapConfigs: [OverlapTransitionConfig?] = []
    private(set) var currentIndex = 0
    private(set) var isLoaded = false
    private(set) var isLoadingSong = false
    private(set) var loadError: String?
    private(set) var currentWaveformSnapshot: LiveSongWaveformSnapshot?
    private(set) var timelineItems: [LiveSetlistTimelineItem] = []

    private var loadedSongID: UUID?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var waveformSnapshotPrefetchTask: Task<Void, Never>?
    private var pendingWaveformSnapshotSongIDs: Set<UUID> = []
    private var waveformSnapshotsBySongID: [UUID: LiveSongWaveformSnapshot] = [:]
    private var prefetchedIncomingPayloads: [AudioEngineManager.PreparedTrackPayload]?
    private var prefetchedIncomingLayout: SongEngineLayout?
    private var prefetchedIncomingSongID: UUID?
    private var incomingPrefetchTask: Task<Void, Never>?

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

    var overlapConfigAfterCurrentSong: OverlapTransitionConfig? {
        guard overlapConfigs.indices.contains(currentIndex) else { return nil }
        return overlapConfigs[currentIndex]
    }

    func song(for id: UUID) -> Song? {
        songs.first { $0.id == id }
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
    }

    func unbindPlaybackHandlers() {
        audioEngine.onPlaybackFinished = nil
    }

    private func bindPlaybackFinishedHandler() {
        bindPlaybackHandlers()
    }

    func configure(setlist: Setlist) {
        bindPlaybackFinishedHandler()
        applySetlistEntries(setlist.sortedEntries)
        currentIndex = 0
        prefetchWaveformSnapshots()
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
            prefetchWaveformSnapshots()
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
        if isLoaded {
            configureOverlapSchedulingIfNeeded()
        }
    }

    private func applySetlistEntries(_ entries: [SetlistEntry]) {
        var syncedSongs: [Song] = []
        var syncedTransitions: [SetlistTransition] = []
        var syncedOverlapConfigs: [OverlapTransitionConfig?] = []
        var syncedTimeline: [LiveSetlistTimelineItem] = []

        var songIndex = 0
        for (index, entry) in entries.enumerated() {
            if entry.isHeader {
                syncedTimeline.append(
                    .header(
                        scrollID: "header-\(entry.persistentModelID)",
                        title: entry.headerTitle ?? ""
                    )
                )
            } else if let song = entry.song {
                let hasNextSong = entries[(index + 1)...].contains { $0.song != nil }
                syncedTimeline.append(
                    .song(
                        songID: song.id,
                        playbackIndex: songIndex,
                        transitionAfter: hasNextSong ? entry.transition : nil
                    )
                )
                syncedSongs.append(song)
                syncedTransitions.append(entry.transition)
                syncedOverlapConfigs.append(entry.transition == .overlap ? entry.overlapConfig : nil)
                songIndex += 1
            }
        }

        songs = syncedSongs
        transitions = syncedTransitions
        overlapConfigs = syncedOverlapConfigs
        timelineItems = syncedTimeline
        pruneWaveformSnapshotCache()
    }

    func waveformSnapshot(for song: Song) -> LiveSongWaveformSnapshot? {
        waveformSnapshotsBySongID[song.id]
    }

    func ensureWaveformSnapshot(for song: Song) {
        guard waveformSnapshotsBySongID[song.id] == nil else { return }
        guard !pendingWaveformSnapshotSongIDs.contains(song.id) else { return }

        pendingWaveformSnapshotSongIDs.insert(song.id)
        Task { @MainActor in
            defer { pendingWaveformSnapshotSongIDs.remove(song.id) }
            guard waveformSnapshotsBySongID[song.id] == nil else { return }
            guard let snapshot = Self.makeWaveformSnapshot(for: song) else { return }
            waveformSnapshotsBySongID[song.id] = snapshot
            if song.id == currentSong?.id {
                currentWaveformSnapshot = snapshot
            }
        }
    }

    func invalidateWaveformSnapshot(for songID: UUID) {
        waveformSnapshotsBySongID.removeValue(forKey: songID)
        if currentSong?.id == songID {
            currentWaveformSnapshot = nil
        }
    }

    private func pruneWaveformSnapshotCache() {
        let activeSongIDs = Set(songs.map(\.id))
        waveformSnapshotsBySongID = waveformSnapshotsBySongID.filter { activeSongIDs.contains($0.key) }
    }

    private func prefetchWaveformSnapshots() {
        waveformSnapshotPrefetchTask?.cancel()
        waveformSnapshotPrefetchTask = Task { @MainActor in
            for song in songs {
                if Task.isCancelled { return }
                if waveformSnapshotsBySongID[song.id] != nil { continue }
                guard let snapshot = Self.makeWaveformSnapshot(for: song) else { continue }
                waveformSnapshotsBySongID[song.id] = snapshot
                if song.id == currentSong?.id {
                    currentWaveformSnapshot = snapshot
                }
                await Task.yield()
            }
        }
    }

    private func handlePlaybackFinished() {
        switch transitionAfterCurrentSong {
        case .continue:
            advanceToNextSong(autoPlay: true)
        case .overlap:
            if audioEngine.isOverlapPlaybackActive, let incoming = nextSong {
                completeActiveOverlapTransition(to: incoming)
            } else {
                advanceToNextSong(autoPlay: true)
            }
        case .stop, .none:
            break
        }
    }

    func loadCurrentSong(autoPlay: Bool = false, preservedTime: TimeInterval? = nil) {
        if let song = currentSong {
            invalidateWaveformSnapshot(for: song.id)
        }
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
        audioEngine.cancelScheduledOverlapStart()
        audioEngine.cancelOverlapPlayback()
        clearIncomingPrefetch()
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
            loadError = nil
            return
        }

        if song.id != loadedSongID {
            isLoaded = false
            currentWaveformSnapshot = nil
        }

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
                loadedSongID = song.id
                isLoaded = true
                loadError = nil

                if let preservedTime {
                    audioEngine.seek(to: preservedTime)
                }
                if autoPlay {
                    audioEngine.play()
                }
                configureOverlapSchedulingIfNeeded()
            } catch {
                loadedSongID = nil
                currentWaveformSnapshot = nil
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
                    sourceDurationForTrack: { Self.trackSourceDuration(for: $0, in: song) },
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )

                let routing = routingProvider?()
                try audioEngine.loadPreparedTracks(prepared, routing: routing)
                applySongEngineState(for: song)
                applyGroupMixFromProvider()
                currentWaveformSnapshot = Self.makeWaveformSnapshot(for: song)
                if let currentWaveformSnapshot {
                    waveformSnapshotsBySongID[song.id] = currentWaveformSnapshot
                }
                loadedSongID = song.id
                isLoaded = true
                loadError = nil

                if let preservedTime {
                    audioEngine.seek(to: preservedTime)
                }
                if autoPlay {
                    audioEngine.play()
                }
                configureOverlapSchedulingIfNeeded()
            } catch {
                loadedSongID = nil
                currentWaveformSnapshot = nil
                isLoaded = false
                loadError = error.localizedDescription
            }

        case .failure(let error):
            if error is CancellationError {
                loadError = nil
            } else {
                loadedSongID = nil
                currentWaveformSnapshot = nil
                isLoaded = false
                loadError = error.localizedDescription
            }
        }
    }

    private func refreshWaveformSnapshots() {
        guard let song = currentSong else {
            currentWaveformSnapshot = nil
            return
        }
        if let cached = waveformSnapshotsBySongID[song.id] {
            currentWaveformSnapshot = cached
            return
        }
        currentWaveformSnapshot = Self.makeWaveformSnapshot(for: song)
        if let currentWaveformSnapshot {
            waveformSnapshotsBySongID[song.id] = currentWaveformSnapshot
        }
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
        let arrangement = projectState.arrangement
        let inputs = Self.arrangementLayoutInputs(for: song, markers: projectState.markers)
        let layout = SongArrangementStore.playbackLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            clipGaps: arrangement.clipGaps,
            clipRegions: arrangement.clipRegions,
            tracks: SongPlaybackArrangementLoader.playbackTracks(for: song),
            inputs: inputs
        )

        let resolvedMIDI = MIDIScheduler.scheduledEvents(
            events: projectState.midiEvents,
            tracks: song.sortedMIDITracks
        )

        return SongEngineLayout(
            sectionsByTrack: layout.trackSections,
            masterSections: layout.rulerSections,
            removedClips: arrangement.removedClips,
            tempoChanges: projectState.tempoChanges,
            timeSignatureChanges: projectState.timeSignatureChanges,
            midiEvents: resolvedMIDI
        )
    }

    private func applySongEngineState(for song: Song) {
        let layout = songEngineLayout(for: song)

        audioEngine.setArrangement(
            sectionsByTrack: layout.sectionsByTrack,
            masterSections: layout.masterSections,
            removedClips: layout.removedClips
        )

        audioEngine.setTempoMap(
            layout.tempoChanges,
            referenceBPM: layout.tempoChanges.referenceBPM,
            timeSignatureChanges: layout.timeSignatureChanges
        )
        audioEngine.configureMIDI(events: layout.midiEvents)
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
        let arrangement = projectState.arrangement
        let inputs = arrangementLayoutInputs(for: song, markers: projectState.markers)
        let playbackLayout = SongArrangementStore.playbackLayoutSnapshot(
            slots: arrangement.slots,
            clipTrims: arrangement.clipTrims,
            removedClips: arrangement.removedClips,
            clipGaps: arrangement.clipGaps,
            clipRegions: arrangement.clipRegions,
            tracks: SongPlaybackArrangementLoader.playbackTracks(for: song),
            inputs: inputs
        )
        let peakSections = waveformPeakSections(
            playbackLayout: playbackLayout,
            rulerSections: playbackLayout.rulerSections
        )
        let timelineDuration = SongArrangementStore.effectiveTimelineDuration(
            rulerSections: playbackLayout.rulerSections,
            trackSections: playbackLayout.trackSections
        )

        return LiveSongWaveformSnapshot(
            songID: song.id,
            songName: song.name,
            trackSources: trackSources,
            fileDuration: fileDuration,
            timelineDuration: timelineDuration,
            sections: playbackLayout.rulerSections,
            peakSections: peakSections,
            loopSlotIDs: arrangement.loopSlotIDs
        )
    }

    /// Uses playback clip regions for peak mapping.
    static func waveformPeakSections(
        playbackLayout: ArrangementLayoutSnapshot,
        rulerSections: [ArrangementDisplaySection]
    ) -> [ArrangementDisplaySection] {
        playbackLayout.trackSections.values
            .first(where: { !$0.isEmpty })
            ?? rulerSections
    }

    private static func clickOnlySettings(for song: Song) -> AudioEngineManager.TrackSettings {
        AudioEngineManager.TrackSettings(
            volume: Float(song.clickTrackVolume),
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

    private static func trackSourceDuration(for trackID: UUID, in song: Song) -> TimeInterval {
        guard let track = song.sortedTracks.first(where: { $0.id == trackID }),
              let url = FileStore.trackURL(for: song, track: track) else { return 1 }
        return FileStore.fileDuration(at: url) ?? 1
    }

    static func arrangementLayoutInputs(
        for song: Song,
        markers: [ArrangementMarker]
    ) -> ArrangementLayoutInputs {
        SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: song.sortedTracks.map(\.id),
            sourceDurationForTrack: { trackSourceDuration(for: $0, in: song) }
        )
    }

    private func configureOverlapSchedulingIfNeeded() {
        audioEngine.cancelScheduledOverlapStart()
        clearIncomingPrefetch()

        guard transitionAfterCurrentSong == .overlap,
              let config = overlapConfigAfterCurrentSong,
              config.isValid,
              let incoming = nextSong,
              let outgoing = currentSong,
              !outgoing.isClickOnly,
              !incoming.isClickOnly else {
            return
        }

        prefetchIncomingSong(incoming)

        let triggerTime = max(0, audioEngine.duration - config.startOffsetSeconds)
        audioEngine.configureScheduledOverlapStart(at: triggerTime) { [weak self] in
            Task { @MainActor in
                self?.startOverlapPlaybackIfReady()
            }
        }
    }

    private func prefetchIncomingSong(_ incoming: Song) {
        incomingPrefetchTask?.cancel()
        prefetchedIncomingPayloads = nil
        prefetchedIncomingLayout = nil
        prefetchedIncomingSongID = incoming.id

        let layout = songEngineLayout(for: incoming)
        prefetchedIncomingLayout = layout
        let trackInputs = SongTrackLoader.trackInputs(for: incoming)

        incomingPrefetchTask = Task { @MainActor in
            let result: Result<[AudioEngineManager.PreparedTrackPayload], Error> =
                await Task.detached(priority: .utility) {
                    do {
                        var prepared = try SongTrackLoader.streamingPayloads(trackInputs: trackInputs)
                        let projectState = SongProjectBridge.projectStateOrDefaults(for: incoming)
                        try SongTrackLoader.appendClickTrackIfNeeded(
                            to: &prepared,
                            song: incoming,
                            sourceDurationForTrack: { Self.trackSourceDuration(for: $0, in: incoming) },
                            tempoChanges: projectState.tempoChanges,
                            timeSignatureChanges: projectState.timeSignatureChanges
                        )
                        return .success(prepared)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard !Task.isCancelled, prefetchedIncomingSongID == incoming.id else { return }
            if case .success(let payloads) = result {
                prefetchedIncomingPayloads = payloads
            }
        }
    }

    private func startOverlapPlaybackIfReady() {
        guard transitionAfterCurrentSong == .overlap,
              let incoming = nextSong,
              prefetchedIncomingSongID == incoming.id,
              let payloads = prefetchedIncomingPayloads,
              let layout = prefetchedIncomingLayout else {
            return
        }

        do {
            try audioEngine.beginOverlapPlayback(
                payloads: payloads,
                sectionsByTrack: layout.sectionsByTrack,
                atMasterTime: audioEngine.currentTime
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func completeActiveOverlapTransition(to incoming: Song) {
        audioEngine.cancelScheduledOverlapStart()
        clearIncomingPrefetch()

        let layout = songEngineLayout(for: incoming)
        let incomingDuration = Self.incomingTimelineDuration(for: incoming, layout: layout)
        _ = audioEngine.completeOverlapTransition(incomingDuration: incomingDuration)

        audioEngine.setArrangement(
            sectionsByTrack: layout.sectionsByTrack,
            masterSections: layout.masterSections,
            removedClips: layout.removedClips
        )
        audioEngine.setTempoMap(
            layout.tempoChanges,
            referenceBPM: layout.tempoChanges.referenceBPM,
            timeSignatureChanges: layout.timeSignatureChanges
        )
        audioEngine.configureMIDI(events: layout.midiEvents)
        applyGroupMixFromProvider()

        currentIndex += 1
        loadedSongID = incoming.id
        isLoaded = true
        loadError = nil
        currentWaveformSnapshot = Self.makeWaveformSnapshot(for: incoming)
        if let currentWaveformSnapshot {
            waveformSnapshotsBySongID[incoming.id] = currentWaveformSnapshot
        }
        configureOverlapSchedulingIfNeeded()
    }

    private func clearIncomingPrefetch() {
        incomingPrefetchTask?.cancel()
        incomingPrefetchTask = nil
        prefetchedIncomingPayloads = nil
        prefetchedIncomingLayout = nil
        prefetchedIncomingSongID = nil
    }

    private static func incomingTimelineDuration(
        for song: Song,
        layout: SongEngineLayout
    ) -> TimeInterval {
        SongArrangementStore.effectiveTimelineDuration(
            rulerSections: layout.masterSections,
            trackSections: layout.sectionsByTrack
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
