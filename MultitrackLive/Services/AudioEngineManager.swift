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
    private var hasFiniteDuration = true

    private struct ClickOnlyState {
        let trackID: UUID
        let player: RealtimeClickTrackPlayer
        var settings: TrackSettings
        var subdivision: ClickTrackSubdivision
        var isEnabled: Bool
        let sourceFormat: AVAudioFormat
    }

    private var clickOnlyState: ClickOnlyState?

    private(set) var groupMeterLevels: [UUID: Float] = [:]
    private(set) var trackMeterLevels: [UUID: Float] = [:]

    /// Practical upper bound for open-ended click-only playback and transport clamping.
    static let openEndedTimelineDuration: TimeInterval = 86_400 * 365

    var isClickOnlyPlayback: Bool {
        clickOnlyState != nil
    }

    var referenceSampleRate: Double {
        DecodedStemBuffer.engineSampleRate
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var onPlaybackFinished: (() -> Void)?

    private init() {
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
        teardownClickOnlyPlayer()
        hasFiniteDuration = true
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

    func loadClickOnlySong(
        trackID: UUID,
        settings: TrackSettings,
        subdivision: ClickTrackSubdivision,
        isEnabled: Bool,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        routing: OutputRoutingSnapshot? = nil
    ) throws {
        stop()
        stopEngineForGraphChanges()
        teardownTracks()
        teardownClickOnlyPlayer()
        outputRoutingManager.teardown(in: engine)
        masterArrangementSections = []
        arrangementSectionsByTrack = [:]
        arrangementRemovedClips = []
        routingSnapshot = routing
        usesOutputRouting = routing != nil
        hasFiniteDuration = false

        self.tempoChanges = tempoChanges.sortedByMeasure
        referenceBPM = self.tempoChanges.referenceBPM
        self.timeSignatureChanges = timeSignatureChanges.sortedByMeasure

        let configuration = RealtimeClickTrackPlayer.Configuration(
            tempoChanges: self.tempoChanges,
            timeSignatureChanges: self.timeSignatureChanges,
            subdivision: subdivision,
            isEnabled: isEnabled,
            volume: settings.volume
        )

        let player = try RealtimeClickTrackPlayer(
            trackID: trackID,
            transport: transport,
            configuration: configuration
        )

        engine.attach(player.sourceNode)
        engine.connect(player.sourceNode, to: masterMixer, format: player.audioFormat)

        clickOnlyState = ClickOnlyState(
            trackID: trackID,
            player: player,
            settings: settings,
            subdivision: subdivision,
            isEnabled: isEnabled,
            sourceFormat: player.audioFormat
        )

        if usesOutputRouting, let routing {
            try wireClickOnlyOutput(routing: routing)
        } else {
            connectTracksToMasterMixer()
            try startEngineIfNeeded()
        }

        applyClickOnlyMixSettings()
        duration = Self.openEndedTimelineDuration
        transport.setDuration(duration)
        syncTransportTempoMap()
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

        guard !tracks.isEmpty || clickOnlyState != nil else {
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
            if clickOnlyState != nil {
                try wireClickOnlyOutput(routing: routing)
            } else {
                try wireTrackOutputs(routing: routing)
            }
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
        syncClickOnlyConfiguration()
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
        transport.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
        midiScheduler.stop()
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
        if var clickOnly = clickOnlyState, clickOnly.trackID == id {
            clickOnly.settings = settings
            clickOnlyState = clickOnly
            applyClickOnlyMixSettings()
            return
        }

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

        if clickOnlyState != nil {
            groupMeterLevels = groupLevels
            trackMeterLevels = trackLevels
            return
        }

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
        if clickOnlyState != nil {
            applyClickOnlyMixSettings()
            return
        }

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

    func updateClickOnlyPlayback(
        subdivision: ClickTrackSubdivision,
        isEnabled: Bool
    ) {
        guard var clickOnly = clickOnlyState else { return }
        clickOnly.subdivision = subdivision
        clickOnly.isEnabled = isEnabled
        clickOnlyState = clickOnly
        syncClickOnlyConfiguration()
        applyClickOnlyMixSettings()
    }

    private var canPlay: Bool {
        !tracks.isEmpty || clickOnlyState != nil
    }

    private func clampedTimelineTime(_ time: TimeInterval) -> TimeInterval {
        if hasFiniteDuration {
            return max(0, min(time, duration))
        }
        return max(0, time)
    }

    private func applyClickOnlyMixSettings() {
        guard let clickOnly = clickOnlyState else { return }

        var effectiveVolume = clickOnly.settings.volume
        var isAudible = clickOnly.isEnabled

        if clickOnly.settings.isMuted {
            effectiveVolume = 0
            isAudible = false
        }

        clickOnly.player.updateMix(
            volume: effectiveVolume,
            isAudible: isAudible
        )
        syncClickOnlyConfiguration()
    }

    private func syncClickOnlyConfiguration() {
        guard let clickOnly = clickOnlyState else { return }
        clickOnly.player.updateConfiguration(
            RealtimeClickTrackPlayer.Configuration(
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges,
                subdivision: clickOnly.subdivision,
                isEnabled: clickOnly.isEnabled,
                volume: clickOnly.settings.volume
            )
        )
    }

    private func teardownClickOnlyPlayer() {
        guard let clickOnly = clickOnlyState else { return }
        engine.disconnectNodeOutput(clickOnly.player.sourceNode)
        engine.detach(clickOnly.player.sourceNode)
        clickOnlyState = nil
    }

    private func wireClickOnlyOutput(routing: OutputRoutingSnapshot) throws {
        guard let clickOnly = clickOnlyState else { return }

        if let uid = routing.deviceUID {
            _ = AudioOutputDeviceService.setSystemDefaultOutputDevice(uid: uid)
        }

        let effectiveChannelCount = effectiveOutputChannelCount(routing: routing)
        stopEngineForGraphChanges()
        outputRoutingManager.teardown(in: engine)
        engine.disconnectNodeOutput(clickOnly.player.sourceNode)

        if effectiveChannelCount > 2 {
            let routeTracks = [(
                sourceNode: clickOnly.player.sourceNode,
                format: clickOnly.sourceFormat,
                destination: OutputRoutingStore.destination(for: nil, snapshot: routing)
            )]

            if outputRoutingManager.applyChannelMapRouting(
                engine: engine,
                tracks: routeTracks,
                outputChannelCount: effectiveChannelCount
            ) {
                try startEngineIfNeeded()
                return
            }
        }

        connectTracksToMasterMixer()
        try startEngineIfNeeded()
    }

    private func calculateEffectiveDuration() -> TimeInterval {
        if !hasFiniteDuration {
            return Self.openEndedTimelineDuration
        }

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
        teardownClickOnlyPlayer()
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

        if let clickOnly = clickOnlyState {
            engine.disconnectNodeOutput(clickOnly.player.sourceNode)
            OutputRoutingManager.clearChannelMap(on: clickOnly.player.sourceNode)
            engine.connect(clickOnly.player.sourceNode, to: masterMixer, format: clickOnly.sourceFormat)
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

            if self.hasFiniteDuration, self.currentTime >= self.duration - (1.0 / self.referenceSampleRate) {
                self.stop()
                self.onPlaybackFinished?()
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
