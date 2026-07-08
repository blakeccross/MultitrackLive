import AVFoundation
import Foundation
import Observation

@Observable
final class OverlapPreviewEngine {
    private let engine = AVAudioEngine()
    private let masterMixer = AVAudioMixerNode()
    private let transport = AudioPlaybackTransport()

    private var outgoingTracks: [OverlapTrackGraphBuilder.BuiltTrack] = []
    private var incomingTracks: [OverlapTrackGraphBuilder.BuiltTrack] = []
    private var playbackTimer: Timer?
    private var loadGeneration = 0

    private var previewStartTime: TimeInterval = 0
    private var incomingStartTime: TimeInterval = 0
    private var previewDuration: TimeInterval = 0

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var loadError: String?

    init() {
        engine.attach(masterMixer)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: nil)
    }

    deinit {
        teardown()
    }

    func load(
        outgoingSong: Song,
        incomingSong: Song,
        startOffsetSeconds: TimeInterval,
        windowDuration: TimeInterval
    ) async {
        loadGeneration += 1
        let generation = loadGeneration

        stop()
        teardownTracks()
        isLoaded = false
        loadError = nil

        let outgoingSnapshot = PlaybackCoordinator.makeWaveformSnapshot(for: outgoingSong)
        let incomingSnapshot = PlaybackCoordinator.makeWaveformSnapshot(for: incomingSong)
        guard let outgoingSnapshot, let incomingSnapshot else {
            loadError = "Unable to load song waveforms."
            return
        }

        guard generation == loadGeneration else { return }

        let outgoingDuration = outgoingSnapshot.timelineDuration
        let clampedOffset = OverlapTransitionTiming.clampedStartOffset(
            startOffsetSeconds,
            windowDuration: windowDuration,
            outgoingDuration: outgoingDuration
        )

        let outgoingWindowStart = max(0, outgoingDuration - windowDuration)
        let incomingLaneOffset = OverlapTransitionTiming.incomingLaneOffset(
            outgoingDuration: outgoingDuration,
            windowDuration: windowDuration,
            startOffsetSeconds: clampedOffset
        )

        previewStartTime = outgoingWindowStart
        incomingStartTime = outgoingWindowStart + incomingLaneOffset
        previewDuration = windowDuration

        do {
            try await loadTracks(for: outgoingSong, isOutgoing: true)
            guard generation == loadGeneration else {
                teardownTracks()
                return
            }
            try await loadTracks(for: incomingSong, isOutgoing: false)
            guard generation == loadGeneration else {
                teardownTracks()
                return
            }
            transport.setDuration(previewStartTime + previewDuration)
            isLoaded = true
        } catch {
            teardownTracks()
            loadError = error.localizedDescription
        }
    }

    func invalidateConfiguration() {
        loadGeneration += 1
        stop()
        teardownTracks()
        isLoaded = false
    }

    func play() {
        guard isLoaded, !isPlaying else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }

            for track in outgoingTracks {
                track.memoryPlayer.setPlaybackWindow(offset: 0, endTimeline: previewStartTime + previewDuration)
                track.memoryPlayer.prewarm(atTimelineSeconds: previewStartTime)
            }
            for track in incomingTracks {
                track.memoryPlayer.setPlaybackWindow(offset: incomingStartTime, endTimeline: nil)
                track.memoryPlayer.prewarm(atTimelineSeconds: incomingStartTime)
            }

            transport.beginPlayback(from: previewStartTime)
            isPlaying = true
            currentTime = 0
            startTimer()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func pause() {
        guard isPlaying else { return }
        refreshCurrentTime()
        transport.pause(capturingTimeline: previewStartTime + currentTime)
        isPlaying = false
        stopTimer()
    }

    func stop() {
        transport.stop()
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func teardown() {
        stop()
        teardownTracks()
        if engine.isRunning {
            engine.stop()
        }
        isLoaded = false
    }

    private func loadTracks(
        for song: Song,
        isOutgoing: Bool
    ) async throws {
        let trackInputs = SongTrackLoader.trackInputs(for: song)
        let payloads = try await Task { @MainActor in
            try SongTrackLoader.streamingPayloads(trackInputs: trackInputs)
        }.value

        let arrangement = SongPlaybackArrangementLoader.sections(for: song)
        var bundles: [OverlapTrackGraphBuilder.BuiltTrack] = []

        for payload in payloads {
            let bundle = try OverlapTrackGraphBuilder.buildTrack(
                payload: payload,
                sections: arrangement.sectionsByTrack[payload.id] ?? arrangement.masterSections,
                transport: transport,
                engine: engine
            )
            bundle.memoryPlayer.updateMix(
                volume: bundle.settings.volume,
                isAudible: !bundle.settings.isMuted
            )
            bundles.append(bundle)
        }

        if isOutgoing {
            outgoingTracks = bundles
            for track in outgoingTracks {
                track.memoryPlayer.setPlaybackWindow(offset: 0, endTimeline: previewStartTime + previewDuration)
                OverlapTrackGraphBuilder.connect(track, to: masterMixer, in: engine)
            }
        } else {
            incomingTracks = bundles
            for track in incomingTracks {
                track.memoryPlayer.setPlaybackWindow(offset: incomingStartTime, endTimeline: nil)
                OverlapTrackGraphBuilder.connect(track, to: masterMixer, in: engine)
            }
        }
    }

    private func teardownTracks() {
        stopEngineIfNeeded()
        for bundle in outgoingTracks + incomingTracks {
            OverlapTrackGraphBuilder.detach(bundle, from: engine)
        }
        outgoingTracks = []
        incomingTracks = []
    }

    private func stopEngineIfNeeded() {
        if engine.isRunning {
            engine.stop()
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.refreshCurrentTime()
            if self.currentTime >= self.previewDuration - (1.0 / 48_000) {
                self.pause()
                self.currentTime = self.previewDuration
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func refreshCurrentTime() {
        let state = transport.renderTimeline(atHostTime: mach_absolute_time(), captureAnchor: true)
        currentTime = max(0, min(state.timelineSeconds - previewStartTime, previewDuration))
    }
}
