import AVFoundation
import Foundation
import Observation

@Observable
final class AudioEngineManager {
    static let shared = AudioEngineManager()

    struct TrackSettings: Equatable {
        var volume: Float
        var isMuted: Bool
        var isSolo: Bool
        var trimStart: TimeInterval
        var trimEnd: TimeInterval?
        var pitchCents: Float
        var excludeFromTranspose: Bool
        var ignoresSolo: Bool = false
        /// Generated stems (e.g. click) that follow the master timeline 1:1.
        var bypassesArrangementMapping: Bool = false
    }

    struct PreparedTrackPayload: Sendable {
        let id: UUID
        let buffer: any StemSampleSource
        let settings: TrackSettings
        let groupID: UUID?
    }

    private struct TrackState {
        let trackID: UUID
        let memoryPlayer: TrackMemoryPlayer
        let timePitchNode: AVAudioUnitTimePitch
        var settings: TrackSettings
        let fileDuration: TimeInterval
        let groupID: UUID?
        let sourceFormat: AVAudioFormat

        var playbackOutputNode: AVAudioNode {
            timePitchNode
        }
    }

    private let engine = AVAudioEngine()
    private let masterMixer = AVAudioMixerNode()
    private let outputRoutingManager = OutputRoutingManager()
    private let transport = AudioPlaybackTransport()
    private let midiScheduler: MIDIScheduler
    private var tracks: [UUID: TrackState] = [:]
    private var overlapTracks: [UUID: TrackState] = [:]
    private(set) var isOverlapPlaybackActive = false
    private var overlapStartMasterTime: TimeInterval = 0
    private var scheduledOverlapStartTime: TimeInterval?
    private var overlapStartHandler: (() -> Void)?
    private var didNotifyPlaybackFinished = false
    private var suppressAutoStopOnPlaybackFinished = false
    private var playbackTimer: Timer?
    private var masterArrangementSections: [ArrangementDisplaySection] = []
    private var arrangementSectionsByTrack: [UUID: [ArrangementDisplaySection]] = [:]
    private var arrangementRemovedClips: [ArrangementRemovedClip] = []
    private var routingSnapshot: OutputRoutingSnapshot?
    private var groupMixSnapshot = GroupMixSnapshot.default
    private var usesOutputRouting = false
    private var tempoChanges: [TempoChange] = []
    private var referenceBPM: Double = 0
    private var timeSignatureChanges: [TimeSignatureChange] = []
    private var lastAppliedPitchCompensationCents: Float?

    private(set) var groupMeterLevels: [UUID: Float] = [:]
    private(set) var trackMeterLevels: [UUID: Float] = [:]

    var referenceSampleRate: Double {
        DecodedStemBuffer.engineSampleRate
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var onPlaybackFinished: (() -> Void)?

    init() {
        midiScheduler = MIDIScheduler(transport: transport)
        engine.attach(masterMixer)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: nil)
        #if os(iOS)
        configureAudioSession()
        #endif
    }

    #if os(iOS)
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
    #endif

    func loadTracks(
        _ payloads: [(id: UUID, url: URL, settings: TrackSettings, groupID: UUID?)],
        routing: OutputRoutingSnapshot? = nil,
        bakePitchShift: Bool = false
    ) throws {
        let prepared = try payloads.map { payload in
            try Self.prepareTrackPayload(
                id: payload.id,
                url: payload.url,
                settings: payload.settings,
                groupID: payload.groupID,
                bakePitchShift: bakePitchShift
            )
        }
        try loadPreparedTracks(prepared, routing: routing)
    }

    func loadPreparedTracks(
        _ payloads: [PreparedTrackPayload],
        routing: OutputRoutingSnapshot? = nil
    ) throws {
        cancelOverlapPlayback()
        stop()
        stopEngineForGraphChanges()
        teardownTracks()
        outputRoutingManager.teardown(in: engine)
        masterArrangementSections = []
        arrangementSectionsByTrack = [:]
        arrangementRemovedClips = []
        routingSnapshot = routing
        usesOutputRouting = routing != nil

        var loadedTracks: [UUID: TrackState] = [:]
        do {
            for payload in payloads {
                loadedTracks[payload.id] = try buildTrackState(for: payload)
            }
            tracks = loadedTracks

            if usesOutputRouting, let routing {
                try wireTrackOutputs(routing: routing)
            } else {
                connectTracksToMasterMixer()
                try startEngineIfNeeded()
            }

            applyAllMixSettings()
            duration = calculateEffectiveDuration()
            transport.setDuration(duration)
        } catch {
            tracks = loadedTracks
            teardownTracks()
            throw error
        }
    }

    static func pitchShiftedBuffer(
        from decodedBuffer: DecodedStemBuffer,
        settings: TrackSettings
    ) throws -> DecodedStemBuffer {
        let semitones = Int((settings.pitchCents / 100).rounded())
        guard semitones != 0 else { return decodedBuffer }
        return try decodedBuffer.applyingSemitoneShift(semitones)
    }

    static func prepareTrackPayload(
        id: UUID,
        decodedBuffer: DecodedStemBuffer,
        settings: TrackSettings,
        groupID: UUID?,
        bakePitchShift: Bool = false
    ) throws -> PreparedTrackPayload {
        let playbackBuffer: DecodedStemBuffer
        var resolvedSettings = settings

        if bakePitchShift {
            playbackBuffer = try pitchShiftedBuffer(from: decodedBuffer, settings: settings)
            if Int((settings.pitchCents / 100).rounded()) != 0 {
                resolvedSettings.pitchCents = 0
            }
        } else {
            playbackBuffer = decodedBuffer
        }

        let fileDuration = Double(playbackBuffer.frameCount) / playbackBuffer.sampleRate
        if resolvedSettings.trimEnd == nil {
            resolvedSettings.trimEnd = fileDuration
        }
        return PreparedTrackPayload(
            id: id,
            buffer: playbackBuffer,
            settings: resolvedSettings,
            groupID: groupID
        )
    }

    static func prepareTrackPayload(
        id: UUID,
        url: URL,
        settings: TrackSettings,
        groupID: UUID?,
        bakePitchShift: Bool = false
    ) throws -> PreparedTrackPayload {
        let decodedBuffer = try DecodedStemBuffer.decode(from: url)
        return try prepareTrackPayload(
            id: id,
            decodedBuffer: decodedBuffer,
            settings: settings,
            groupID: groupID,
            bakePitchShift: bakePitchShift
        )
    }

    private func buildTrackState(for payload: PreparedTrackPayload) throws -> TrackState {
        var settings = payload.settings
        let playbackBuffer = payload.buffer
        let fileDuration = Double(playbackBuffer.frameCount) / playbackBuffer.sampleRate
        if settings.trimEnd == nil {
            settings.trimEnd = fileDuration
        }

        let mapper = makeMapper(
            trackID: payload.id,
            settings: settings,
            fileDuration: fileDuration
        )
        let memoryPlayer = TrackMemoryPlayer(
            trackID: payload.id,
            buffer: playbackBuffer,
            transport: transport,
            mapper: mapper
        )

        let timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.pitch = settings.pitchCents
        timePitchNode.rate = 1.0

        let format = playbackBuffer.audioFormat
        engine.attach(memoryPlayer.sourceNode)
        engine.attach(timePitchNode)
        engine.connect(memoryPlayer.sourceNode, to: timePitchNode, format: format)

        return TrackState(
            trackID: payload.id,
            memoryPlayer: memoryPlayer,
            timePitchNode: timePitchNode,
            settings: settings,
            fileDuration: fileDuration,
            groupID: payload.groupID,
            sourceFormat: format
        )
    }

    func applyOutputRouting(_ routing: OutputRoutingSnapshot) {
        routingSnapshot = routing
        usesOutputRouting = true

        guard !tracks.isEmpty else {
            if let uid = routing.deviceUID {
                _ = AudioOutputDeviceService.setSystemDefaultOutputDevice(uid: uid)
            }
            return
        }

        let wasPlaying = isPlaying
        let preservedTime = currentTime

        if wasPlaying {
            pause()
        }

        stopEngineForGraphChanges()

        do {
            try wireTrackOutputs(routing: routing)
            duration = calculateEffectiveDuration()
            transport.setDuration(duration)
            syncTransportTempoMap()
            currentTime = min(preservedTime, duration)
            transport.setPausedTimeline(currentTime)

            if wasPlaying {
                play()
            }
        } catch {
            isPlaying = false
            stopTimer()
        }
    }

    func setArrangement(
        sectionsByTrack: [UUID: [ArrangementDisplaySection]],
        masterSections: [ArrangementDisplaySection],
        removedClips: [ArrangementRemovedClip] = []
    ) {
        if isPlaying {
            refreshCurrentTimeFromEngine()
        }

        let preservedTime = min(currentTime, masterSections.last?.timelineEndSeconds ?? currentTime)
        arrangementSectionsByTrack = sectionsByTrack
        masterArrangementSections = masterSections
        arrangementRemovedClips = removedClips
        duration = calculateEffectiveDuration()
        transport.setDuration(duration)
        syncTransportTempoMap()
        currentTime = min(preservedTime, duration)
        transport.setPausedTimeline(currentTime)
        transport.cancelScheduledTransition()
        refreshTrackMappers()
    }

    /// Updates one track's arrangement mapping without disturbing transport or other tracks.
    func updateTrackArrangement(
        trackID: UUID,
        sections: [ArrangementDisplaySection],
        removedClips: [ArrangementRemovedClip]
    ) {
        arrangementSectionsByTrack[trackID] = sections
        arrangementRemovedClips = removedClips
        refreshTrackMapper(for: trackID)
    }

    func setArrangement(_ sections: [ArrangementDisplaySection]) {
        setArrangement(sectionsByTrack: [:], masterSections: sections, removedClips: [])
    }

    func setTempoMap(
        _ changes: [TempoChange],
        referenceBPM: Double,
        timeSignatureChanges: [TimeSignatureChange]
    ) {
        tempoChanges = changes.sortedByMeasure
        self.referenceBPM = referenceBPM
        self.timeSignatureChanges = timeSignatureChanges.sortedByMeasure
        syncTransportTempoMap()
        applyTrackPitch()
    }

    private func syncTransportTempoMap() {
        guard referenceBPM > 0, !tempoChanges.isEmpty else { return }
        transport.setTempoMap(
            changes: tempoChanges,
            referenceBPM: referenceBPM,
            timeSignatureChanges: timeSignatureChanges,
            duration: duration
        )
    }

    func play() {
        guard canPlay, !isPlaying else { return }
        if !engine.isRunning {
            try? engine.start()
        }

        let startTime = quantizeTimelineTime(transport.pausedTimelineSeconds())
        applyTrackPitch(at: startTime)
        prewarmTracks(atTimelineSeconds: startTime)
        transport.beginPlayback(from: startTime)
        isPlaying = true
        didNotifyPlaybackFinished = false
        startTimer()
        midiScheduler.start()
        refreshCurrentTimeFromEngine()
    }

    func pause() {
        guard isPlaying else { return }
        let timeline = livePlayheadTime()
        transport.pause(capturingTimeline: timeline)
        isPlaying = false
        stopTimer()
        midiScheduler.stop()
        currentTime = timeline
    }

    func stop() {
        cancelScheduledOverlapStart()
        cancelOverlapPlayback()
        didNotifyPlaybackFinished = false
        transport.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
        midiScheduler.stop()
    }

    /// When true, this engine will not call `stop()` automatically when it reaches
    /// the end of its timeline. Useful for external handoffs (e.g. crossfades
    /// between two independent engines).
    func setSuppressAutoStopOnPlaybackFinished(_ suppress: Bool) {
        suppressAutoStopOnPlaybackFinished = suppress
    }

    /// Sets a master output gain for this engine. This is used for crossfades
    /// between two engines.
    func setMasterVolume(_ volume: Float) {
        masterMixer.outputVolume = volume
    }

    /// Updates the transport timeline without swapping the audio graph.
    ///
    /// This is useful when another engine is providing audible output but the
    /// app needs a consistent playhead for UI (e.g. overlap crossfades).
    func retargetTimeline(duration newDuration: TimeInterval, at timelineSeconds: TimeInterval) {
        // Reset end-of-playback notification state for the new duration.
        didNotifyPlaybackFinished = false

        let clampedDuration = max(0, newDuration)
        duration = clampedDuration

        transport.setDuration(clampedDuration)

        let clampedTimeline = quantizeTimelineTime(max(0, min(timelineSeconds, clampedDuration)))
        currentTime = clampedTimeline
        transport.setPausedTimeline(clampedTimeline)

        if isPlaying, let hostTime = currentHostTime() {
            // Re-anchor so wall time continues from the right timeline instantly.
            transport.resetAnchor(to: clampedTimeline, hostTime: hostTime)
        }
    }

    func configureScheduledOverlapStart(at time: TimeInterval?, handler: (() -> Void)?) {
        scheduledOverlapStartTime = time
        overlapStartHandler = handler
    }

    func cancelScheduledOverlapStart() {
        scheduledOverlapStartTime = nil
        overlapStartHandler = nil
    }

    func beginOverlapPlayback(
        payloads: [PreparedTrackPayload],
        sectionsByTrack: [UUID: [ArrangementDisplaySection]],
        atMasterTime masterTime: TimeInterval
    ) throws {
        guard !isOverlapPlaybackActive, !payloads.isEmpty else { return }

        let quantizedStart = quantizeTimelineTime(masterTime)
        overlapStartMasterTime = quantizedStart
        isOverlapPlaybackActive = true

        for payload in payloads {
            let sections = sectionsByTrack[payload.id] ?? []
            let trackState = try buildOverlapTrackState(for: payload, sections: sections)
            overlapTracks[payload.id] = trackState
            trackState.memoryPlayer.setPlaybackWindow(offset: quantizedStart, endTimeline: nil)
            connectOverlapTrackToMasterMixer(trackState)
        }

        applyOverlapMixSettings()
        prewarmOverlapTracks(atTimelineSeconds: quantizedStart)
    }

    /// Promotes overlap tracks to primary and returns the incoming song timeline position.
    @discardableResult
    func completeOverlapTransition(incomingDuration: TimeInterval) -> TimeInterval {
        guard isOverlapPlaybackActive else { return 0 }

        // This method runs at an "audible" boundary. We reset the finish-notification
        // guard so the incoming song can finish later, and we re-anchor transport
        // so the timeline stays continuous.
        didNotifyPlaybackFinished = false

        let incomingTimeline = max(0, currentTime - overlapStartMasterTime)
        cancelScheduledOverlapStart()

        // Prevent any pending timeline warps from the outgoing song from affecting the
        // incoming song immediately after promotion.
        transport.cancelScheduledTransition()

        // Keep the engine running so we don't introduce a tiny silence gap.
        teardownTracks(withIDs: Set(tracks.keys), stopEngine: false)

        tracks = overlapTracks
        overlapTracks = [:]
        isOverlapPlaybackActive = false
        overlapStartMasterTime = 0

        for id in tracks.keys {
            tracks[id]?.memoryPlayer.setPlaybackWindow(offset: 0, endTimeline: nil)
        }

        duration = incomingDuration
        transport.setDuration(incomingDuration)

        let clampedIncoming = quantizeTimelineTime(min(incomingTimeline, incomingDuration))
        currentTime = clampedIncoming
        if isPlaying {
            // Re-anchor the shared transport at the new song's timeline position using
            // the current render host time, so timeline mapping continues without waiting
            // for the next render callback.
            if let hostTime = currentHostTime() {
                transport.resetAnchor(to: clampedIncoming, hostTime: hostTime)
            } else {
                transport.setPausedTimeline(clampedIncoming)
                transport.beginPlayback(from: clampedIncoming)
            }
        } else {
            transport.setPausedTimeline(clampedIncoming)
        }

        applyAllMixSettings()
        return clampedIncoming
    }

    func cancelOverlapPlayback() {
        guard isOverlapPlaybackActive || !overlapTracks.isEmpty else {
            isOverlapPlaybackActive = false
            overlapStartMasterTime = 0
            return
        }

        teardownOverlapTracks()
        isOverlapPlaybackActive = false
        overlapStartMasterTime = 0
    }

    func seek(to time: TimeInterval) {
        let clamped = quantizeTimelineTime(clampedTimelineTime(time))
        transport.cancelScheduledTransition()
        currentTime = clamped
        transport.setPausedTimeline(clamped)
        applyTrackPitch(at: clamped)
        prewarmTracks(atTimelineSeconds: clamped)
        midiScheduler.reset(toTimeline: clamped)

        if isPlaying {
            transport.beginPlayback(from: clamped)
        }
    }

    /// Configures MIDI playback for the current song with fully-resolved events.
    /// Events are sent in sync with the shared transport during playback.
    func configureMIDI(events: [MIDIScheduler.ScheduledEvent]) {
        midiScheduler.configure(events: events)
    }

    /// Restarts the engine after graph edits that require a full stop and re-anchors transport.
    private func restorePlaybackClock(at timeline: TimeInterval, afterGraphChange wasPlaying: Bool) {
        let clamped = quantizeTimelineTime(clampedTimelineTime(timeline))
        currentTime = clamped
        transport.setPausedTimeline(clamped)

        guard wasPlaying else { return }

        try? startEngineIfNeeded()
        let hostTime = currentHostTime() ?? mach_absolute_time()
        transport.resetAnchor(to: clamped, hostTime: hostTime)
        refreshCurrentTimeFromEngine()
    }

    private static func duration(
        for masterSections: [ArrangementDisplaySection],
        tracks: [(trimStart: TimeInterval, trimEnd: TimeInterval)]
    ) -> TimeInterval {
        if !masterSections.isEmpty {
            return masterSections.last?.timelineEndSeconds ?? 0
        }

        return tracks.map { max(0, $0.trimEnd - $0.trimStart) }.max() ?? 0
    }

    private func prewarmTracks(atTimelineSeconds timeline: TimeInterval, trackIDs: Set<UUID>? = nil) {
        for track in tracks.values {
            if let trackIDs, !trackIDs.contains(track.trackID) { continue }
            track.memoryPlayer.prewarm(atTimelineSeconds: timeline)
        }
    }

    func scheduleTransition(to targetOffset: TimeInterval, at transitionTimelineTime: TimeInterval) {
        let target = quantizeTimelineTime(clampedTimelineTime(targetOffset))
        let transitionAt = quantizeTimelineTime(clampedTimelineTime(transitionTimelineTime))

        if isPlaying {
            refreshCurrentTimeFromEngine()
        }

        currentTime = quantizeTimelineTime(currentTime)
        transport.setPausedTimeline(currentTime)

        let sampleThreshold = 1.0 / referenceSampleRate
        if transitionAt <= currentTime + sampleThreshold {
            transport.clearScheduledTransition()
            seek(to: target)
            if !isPlaying {
                play()
            }
            return
        }

        transport.scheduleTransition(to: target, at: transitionAt)
    }

    func cancelScheduledTransition() {
        transport.cancelScheduledTransition()
    }

    func snapToTransitionTarget(_ targetOffset: TimeInterval) {
        let target = quantizeTimelineTime(clampedTimelineTime(targetOffset))
        transport.clearScheduledTransition()
        currentTime = target
        transport.setPausedTimeline(target)
        midiScheduler.reset(toTimeline: target)

        if isPlaying, let hostTime = currentHostTime() {
            transport.resetAnchor(to: target, hostTime: hostTime)
        }
    }

    func updateTrackSettings(id: UUID, settings: TrackSettings) {
        guard var track = tracks[id] else { return }
        track.settings = settings
        tracks[id] = track
        applyTrackPitch()
        applyAllMixSettings()
        duration = calculateEffectiveDuration()
        transport.setDuration(duration)
        syncTransportTempoMap()
        refreshTrackMappers()
    }

    func applyGroupMix(_ snapshot: GroupMixSnapshot) {
        groupMixSnapshot = snapshot
        applyAllMixSettings()
    }

    func refreshGroupMeters(decay: Float = 0.55) {
        var groupLevels: [UUID: Float] = [:]
        var trackLevels: [UUID: Float] = [:]

        for track in tracks.values {
            let peak = track.memoryPlayer.consumePeakMeter(decay: decay)
            trackLevels[track.trackID] = peak
            let groupKey = track.groupID ?? OutputRoutingStore.ungroupedRouteID
            groupLevels[groupKey] = max(groupLevels[groupKey] ?? 0, peak)
        }

        groupMeterLevels = groupLevels
        trackMeterLevels = trackLevels
    }

    func trackMeterLevel(for trackID: UUID) -> Float {
        trackMeterLevels[trackID] ?? 0
    }

    func groupMeterLevel(for groupID: UUID?) -> Float {
        let key = groupID ?? OutputRoutingStore.ungroupedRouteID
        return groupMeterLevels[key] ?? 0
    }

    func applyAllMixSettings() {
        let anySolo = tracks.values.contains { $0.settings.isSolo }
        let snapshot = groupMixSnapshot

        for id in tracks.keys {
            guard let track = tracks[id] else { continue }
            var effectiveVolume = track.settings.volume
            var isAudible = true

            if anySolo {
                if !track.settings.isSolo, !track.settings.ignoresSolo {
                    effectiveVolume = 0
                    isAudible = false
                }
            } else if track.settings.isMuted {
                effectiveVolume = 0
                isAudible = false
            }

            let groupVolume: Float
            let groupMuted: Bool
            if let groupID = track.groupID {
                groupVolume = snapshot.volumeByGroupID[groupID] ?? 1
                groupMuted = snapshot.mutedGroupIDs.contains(groupID)
            } else {
                groupVolume = snapshot.ungroupedVolume
                groupMuted = snapshot.ungroupedIsMuted
            }
            effectiveVolume *= groupMuted ? 0 : groupVolume

            track.memoryPlayer.updateMix(
                volume: effectiveVolume,
                isAudible: isAudible
            )
        }
    }

    private var usesArrangement: Bool {
        !masterArrangementSections.isEmpty
    }

    private func makeMapper(
        trackID: UUID,
        settings: TrackSettings,
        fileDuration: TimeInterval
    ) -> ArrangementTimelineMapper {
        if settings.bypassesArrangementMapping {
            return ArrangementTimelineMapper(
                sections: [],
                trimStart: settings.trimStart,
                trimEnd: settings.trimEnd ?? fileDuration,
                usesArrangement: false
            )
        }

        let sections = arrangementSectionsByTrack[trackID] ?? []
        let trackUsesArrangement = usesArrangement || !sections.isEmpty
        return ArrangementTimelineMapper(
            sections: sections,
            trimStart: settings.trimStart,
            trimEnd: settings.trimEnd ?? fileDuration,
            usesArrangement: trackUsesArrangement
        )
    }

    private func refreshTrackMappers() {
        for id in tracks.keys {
            refreshTrackMapper(for: id)
        }
    }

    private func refreshTrackMapper(for trackID: UUID) {
        guard var track = tracks[trackID] else { return }
        let mapper = makeMapper(
            trackID: trackID,
            settings: track.settings,
            fileDuration: track.fileDuration
        )
        track.memoryPlayer.updateMapper(mapper)
        tracks[trackID] = track
    }

    private var canPlay: Bool {
        !tracks.isEmpty
    }

    private func clampedTimelineTime(_ time: TimeInterval) -> TimeInterval {
        max(0, min(time, duration))
    }

    private func calculateEffectiveDuration() -> TimeInterval {
        let trackEnd = arrangementSectionsByTrack.values
            .flatMap { $0 }
            .map(\.timelineEndSeconds)
            .max() ?? 0

        if usesArrangement || trackEnd > 0 {
            return SongArrangementStore.effectiveTimelineDuration(
                rulerSections: usesArrangement ? masterArrangementSections : [],
                trackSections: arrangementSectionsByTrack
            )
        }

        return tracks.values.map { track in
            let end = track.settings.trimEnd ?? track.fileDuration
            return max(0, end - track.settings.trimStart)
        }.max() ?? 0
    }

    private func buildOverlapTrackState(
        for payload: PreparedTrackPayload,
        sections: [ArrangementDisplaySection]
    ) throws -> TrackState {
        let built = try OverlapTrackGraphBuilder.buildTrack(
            payload: payload,
            sections: sections,
            transport: transport,
            engine: engine
        )
        return TrackState(
            trackID: built.trackID,
            memoryPlayer: built.memoryPlayer,
            timePitchNode: built.timePitchNode,
            settings: built.settings,
            fileDuration: built.fileDuration,
            groupID: built.groupID,
            sourceFormat: built.sourceFormat
        )
    }

    private func connectOverlapTrackToMasterMixer(_ track: TrackState) {
        OverlapTrackGraphBuilder.connectToMasterMixer(
            playbackOutputNode: track.playbackOutputNode,
            sourceFormat: track.sourceFormat,
            mixer: masterMixer,
            in: engine
        )
    }

    private func applyOverlapMixSettings() {
        for id in overlapTracks.keys {
            guard let track = overlapTracks[id] else { continue }
            var effectiveVolume = track.settings.volume
            var isAudible = true

            if track.settings.isMuted {
                effectiveVolume = 0
                isAudible = false
            }

            let groupVolume: Float
            let groupMuted: Bool
            if let groupID = track.groupID {
                groupVolume = groupMixSnapshot.volumeByGroupID[groupID] ?? 1
                groupMuted = groupMixSnapshot.mutedGroupIDs.contains(groupID)
            } else {
                groupVolume = groupMixSnapshot.ungroupedVolume
                groupMuted = groupMixSnapshot.ungroupedIsMuted
            }
            effectiveVolume *= groupMuted ? 0 : groupVolume

            track.memoryPlayer.updateMix(
                volume: effectiveVolume,
                isAudible: isAudible
            )
        }
    }

    private func prewarmOverlapTracks(atTimelineSeconds timeline: TimeInterval) {
        for track in overlapTracks.values {
            track.memoryPlayer.prewarm(atTimelineSeconds: timeline)
        }
    }

    private func teardownOverlapTracks() {
        guard !overlapTracks.isEmpty else { return }
        stopEngineForGraphChanges()
        for track in overlapTracks.values {
            OverlapTrackGraphBuilder.detachPlayerGraph(
                memoryPlayer: track.memoryPlayer,
                timePitchNode: track.timePitchNode,
                from: engine
            )
        }
        overlapTracks.removeAll()
    }

    private func teardownTracks(withIDs ids: Set<UUID>, stopEngine: Bool = true) {
        guard !ids.isEmpty else { return }
        if stopEngine {
            stopEngineForGraphChanges()
        }
        for id in ids {
            guard let track = tracks[id] else { continue }
            engine.disconnectNodeOutput(track.memoryPlayer.sourceNode)
            engine.disconnectNodeInput(track.timePitchNode)
            engine.disconnectNodeOutput(track.timePitchNode)
            engine.detach(track.memoryPlayer.sourceNode)
            engine.detach(track.timePitchNode)
            tracks.removeValue(forKey: id)
        }
    }

    private func teardownTracks() {
        stopEngineForGraphChanges()
        for track in tracks.values {
            engine.disconnectNodeOutput(track.memoryPlayer.sourceNode)
            engine.disconnectNodeInput(track.timePitchNode)
            engine.disconnectNodeOutput(track.timePitchNode)
            engine.detach(track.memoryPlayer.sourceNode)
            engine.detach(track.timePitchNode)
        }
        tracks.removeAll()
        outputRoutingManager.teardown(in: engine)
        usesOutputRouting = false
        routingSnapshot = nil
    }

    private func stopEngineForGraphChanges() {
        if engine.isRunning {
            engine.stop()
        }
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func wireTrackOutputs(routing: OutputRoutingSnapshot) throws {
        if let uid = routing.deviceUID {
            _ = AudioOutputDeviceService.setSystemDefaultOutputDevice(uid: uid)
        }

        let effectiveChannelCount = effectiveOutputChannelCount(routing: routing)
        stopEngineForGraphChanges()

        disconnectTrackOutputs()
        connectTrackOutputs(routing: routing, effectiveChannelCount: effectiveChannelCount)

        try startEngineIfNeeded()
    }

    private func disconnectTrackOutputs() {
        outputRoutingManager.teardown(in: engine)
        for track in tracks.values {
            engine.disconnectNodeOutput(track.playbackOutputNode)
        }
    }

    private func connectTrackOutputs(routing: OutputRoutingSnapshot, effectiveChannelCount: Int) {
        if effectiveChannelCount > 2 {
            let routeTracks = tracks.values.map { track in
                (
                    sourceNode: track.playbackOutputNode,
                    format: track.sourceFormat,
                    destination: OutputRoutingStore.destination(for: track.groupID, snapshot: routing)
                )
            }

            if outputRoutingManager.applyChannelMapRouting(
                engine: engine,
                tracks: routeTracks,
                outputChannelCount: effectiveChannelCount
            ) {
                return
            }
        }

        connectTracksToMasterMixer()
    }

    private func connectTracksToMasterMixer() {
        outputRoutingManager.teardown(in: engine)

        engine.disconnectNodeOutput(engine.mainMixerNode)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        for track in tracks.values {
            connectTrackToMasterMixer(track)
        }
    }

    private func connectTrackToMasterMixer(_ track: TrackState) {
        engine.disconnectNodeOutput(track.playbackOutputNode)
        OutputRoutingManager.clearChannelMap(on: track.playbackOutputNode)
        engine.connect(track.playbackOutputNode, to: masterMixer, format: track.sourceFormat)
    }

    private func connectTrackToRoutedOutput(
        _ track: TrackState,
        routing: OutputRoutingSnapshot,
        effectiveChannelCount: Int
    ) {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(effectiveChannelCount)
        ) else {
            connectTrackToMasterMixer(track)
            return
        }

        let destination = OutputRoutingStore.destination(for: track.groupID, snapshot: routing)
        let map = OutputRoutingManager.channelMap(for: destination, outputChannelCount: effectiveChannelCount)
        guard map.contains(where: { $0.intValue >= 0 }) else {
            connectTrackToMasterMixer(track)
            return
        }

        track.playbackOutputNode.auAudioUnit.channelMap = map
        engine.disconnectNodeOutput(track.playbackOutputNode)
        engine.connect(track.playbackOutputNode, to: engine.mainMixerNode, format: outputFormat)
    }

    private func effectiveOutputChannelCount(routing: OutputRoutingSnapshot) -> Int {
        let engineCount = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
        let deviceCount = AudioOutputDeviceService.channelCount(for: routing.deviceUID)
        return max(engineCount, routing.channelCount, deviceCount, 2)
    }

    private func quantizeTimelineTime(_ time: TimeInterval) -> TimeInterval {
        AudioTimelineMath.quantize(time, sampleRate: referenceSampleRate)
    }

    private func startTimer() {
        stopTimer()
        // Scheduled in `.common` modes so the playhead keeps advancing while the
        // run loop is in an event-tracking mode (e.g. an open context menu or an
        // active scroll), instead of freezing while audio continues to play.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.refreshCurrentTimeFromEngine()
            self.applyTrackPitch(at: self.currentTime)

            if !self.didNotifyPlaybackFinished,
               self.currentTime >= self.duration - (1.0 / self.referenceSampleRate) {
                self.didNotifyPlaybackFinished = true
                if self.isOverlapPlaybackActive || self.suppressAutoStopOnPlaybackFinished {
                    self.onPlaybackFinished?()
                } else {
                    self.stop()
                    self.onPlaybackFinished?()
                }
                return
            }

            if let scheduledStart = self.scheduledOverlapStartTime,
               !self.isOverlapPlaybackActive,
               self.currentTime >= scheduledStart {
                self.scheduledOverlapStartTime = nil
                let handler = self.overlapStartHandler
                self.overlapStartHandler = nil
                handler?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func refreshCurrentTimeFromEngine() {
        currentTime = livePlayheadTime()
    }

    private func applyTrackPitch(at timeline: TimeInterval? = nil) {
        let compensationCents: Float
        if let timeline, referenceBPM > 0, !tempoChanges.isEmpty {
            let ratio = transport.playbackRatio(at: timeline)
            compensationCents = Float(-1200 * log2(max(ratio, 0.01)))
        } else {
            compensationCents = 0
        }

        if let timeline,
           let lastAppliedPitchCompensationCents,
           abs(lastAppliedPitchCompensationCents - compensationCents) < 0.01 {
            return
        }
        if timeline != nil {
            lastAppliedPitchCompensationCents = compensationCents
        } else {
            lastAppliedPitchCompensationCents = nil
        }

        for id in tracks.keys {
            guard let track = tracks[id] else { continue }
            track.timePitchNode.rate = 1.0
            track.timePitchNode.pitch = track.settings.pitchCents + compensationCents
        }
    }

    /// Host-clock playhead position for UI rendering without publishing observable updates.
    func livePlayheadTime() -> TimeInterval {
        if let hostTime = currentHostTime() {
            return transport.timelineSeconds(atHostTime: hostTime)
        }
        return transport.pausedTimelineSeconds()
    }

    private func currentHostTime() -> UInt64? {
        guard let lastRenderTime = engine.outputNode.lastRenderTime,
              lastRenderTime.isHostTimeValid else { return nil }
        return lastRenderTime.hostTime
    }
}

extension AudioEngineManager.TrackSettings {
    init(track: AudioTrack) {
        volume = Float(track.volume)
        isMuted = track.isMuted
        isSolo = track.isSolo
        trimStart = track.trimStartSeconds
        trimEnd = track.trimEndSeconds
        excludeFromTranspose = track.excludeFromTranspose
        let semitones = track.song?.transposeSemitones ?? 0
        pitchCents = track.excludeFromTranspose ? 0 : Float(semitones * 100)
    }
}
