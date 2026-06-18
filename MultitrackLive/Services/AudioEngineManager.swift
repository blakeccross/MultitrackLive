import AVFoundation
import Foundation
import Observation

@Observable
final class AudioEngineManager {
    static let shared = AudioEngineManager()

    struct TrackSettings: Equatable {
        var volume: Float
        var pan: Float
        var isMuted: Bool
        var isSolo: Bool
        var trimStart: TimeInterval
        var trimEnd: TimeInterval?
        var pitchCents: Float
        var excludeFromTranspose: Bool
    }

    struct PreparedTrackPayload: Sendable {
        let id: UUID
        let buffer: DecodedStemBuffer
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
    private var tracks: [UUID: TrackState] = [:]
    private var playbackTimer: Timer?
    private var masterArrangementSections: [ArrangementDisplaySection] = []
    private var arrangementSectionsByTrack: [UUID: [ArrangementDisplaySection]] = [:]
    private var arrangementRemovedClips: [ArrangementRemovedClip] = []
    private var routingSnapshot: OutputRoutingSnapshot?
    private var usesOutputRouting = false
    private var tempoChanges: [TempoChange] = []
    private var referenceBPM: Double = 0
    private var timeSignatureChanges: [TimeSignatureChange] = []
    private var lastAppliedPitchCompensationCents: Float?

    var referenceSampleRate: Double {
        DecodedStemBuffer.engineSampleRate
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var onPlaybackFinished: (() -> Void)?

    private init() {
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
        guard !tracks.isEmpty, !isPlaying else { return }
        if !engine.isRunning {
            try? engine.start()
        }

        let startTime = quantizeTimelineTime(transport.pausedTimelineSeconds())
        applyTrackPitch(at: startTime)
        transport.beginPlayback(from: startTime)
        isPlaying = true
        startTimer()
        refreshCurrentTimeFromEngine()
    }

    func pause() {
        guard isPlaying else { return }
        let timeline = livePlayheadTime()
        transport.pause(capturingTimeline: timeline)
        isPlaying = false
        stopTimer()
        currentTime = timeline
    }

    func stop() {
        transport.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: TimeInterval) {
        let clamped = quantizeTimelineTime(max(0, min(time, duration)))
        transport.cancelScheduledTransition()
        currentTime = clamped
        transport.setPausedTimeline(clamped)
        applyTrackPitch(at: clamped)

        if isPlaying {
            transport.beginPlayback(from: clamped)
        }
    }

    func scheduleTransition(to targetOffset: TimeInterval, at transitionTimelineTime: TimeInterval) {
        let target = quantizeTimelineTime(max(0, min(targetOffset, duration)))
        let transitionAt = quantizeTimelineTime(max(0, min(transitionTimelineTime, duration)))

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
        let target = quantizeTimelineTime(max(0, min(targetOffset, duration)))
        transport.clearScheduledTransition()
        currentTime = target
        transport.setPausedTimeline(target)

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

    func applyAllMixSettings() {
        let anySolo = tracks.values.contains { $0.settings.isSolo }

        for id in tracks.keys {
            guard let track = tracks[id] else { continue }
            var effectiveVolume = track.settings.volume
            var isAudible = true

            if anySolo {
                if !track.settings.isSolo {
                    effectiveVolume = 0
                    isAudible = false
                }
            } else if track.settings.isMuted {
                effectiveVolume = 0
                isAudible = false
            }

            track.memoryPlayer.updateMix(
                volume: effectiveVolume,
                pan: track.settings.pan,
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
        let sections = arrangementSectionsByTrack[trackID] ?? []
        return ArrangementTimelineMapper(
            sections: sections,
            trimStart: settings.trimStart,
            trimEnd: settings.trimEnd ?? fileDuration,
            usesArrangement: usesArrangement
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

    private func calculateEffectiveDuration() -> TimeInterval {
        if usesArrangement {
            return masterArrangementSections.last?.timelineEndSeconds ?? 0
        }

        return tracks.values.map { track in
            let end = track.settings.trimEnd ?? track.fileDuration
            return max(0, end - track.settings.trimStart)
        }.max() ?? 0
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
            engine.disconnectNodeOutput(track.playbackOutputNode)
            OutputRoutingManager.clearChannelMap(on: track.playbackOutputNode)
            engine.connect(track.playbackOutputNode, to: masterMixer, format: track.sourceFormat)
        }
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
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.refreshCurrentTimeFromEngine()
            self.applyTrackPitch(at: self.currentTime)
            if self.currentTime >= self.duration {
                self.stop()
                self.onPlaybackFinished?()
            }
        }
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
        pan = Float(track.pan)
        isMuted = track.isMuted
        isSolo = track.isSolo
        trimStart = track.trimStartSeconds
        trimEnd = track.trimEndSeconds
        excludeFromTranspose = track.excludeFromTranspose
        let semitones = track.song?.transposeSemitones ?? 0
        pitchCents = track.excludeFromTranspose ? 0 : Float(semitones * 100)
    }
}
