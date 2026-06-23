import SwiftUI

/// A single playhead line spanning the ruler and all track lanes.
/// Updates on a display-linked cadence during playback without invalidating waveform views.
struct TimelinePlayheadOverlay: View {
    @Bindable private var audioEngine = AudioEngineManager.shared
    let duration: TimeInterval
    let contentWidth: CGFloat
    let height: CGFloat

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    var body: some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    playheadLine(at: audioEngine.livePlayheadTime())
                }
            } else {
                playheadLine(at: audioEngine.currentTime)
            }
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func playheadLine(at time: TimeInterval) -> some View {
        let x = TimelineLayout.xPosition(
            for: min(max(0, time), safeDuration),
            duration: safeDuration,
            contentWidth: contentWidth
        )

        Rectangle()
            .fill(Color.orange)
            .frame(width: 2, height: height)
            .offset(x: x - 1)
    }
}

/// Wires section-loop monitoring and playback-time handling into a timeline view.
struct SectionLoopPlaybackSupport: View {
    @Bindable private var audioEngine = AudioEngineManager.shared
    @Bindable var loopController: SectionLoopController
    let sections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>
    let onLoop: (ArrangementDisplaySection) -> Void
    let onLoopActivated: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background {
                SectionLoopMonitor(
                    activeLoopSection: loopController.activeSection(
                        in: sections,
                        loopSlotIDs: loopSlotIDs
                    ),
                    onLoop: fireLoopIfNeeded
                )
            }
            .onChange(of: audioEngine.currentTime) { _, time in
                loopController.handlePlaybackTimeChange(
                    at: time,
                    sections: sections,
                    loopSlotIDs: loopSlotIDs,
                    onActivate: onLoopActivated
                )
            }
            .onChange(of: loopSlotIDs) { _, newLoopSlotIDs in
                loopController.handleLoopSlotIDsChange(newLoopSlotIDs)
            }
    }

    private func fireLoopIfNeeded() {
        guard let section = loopController.activeSection(in: sections, loopSlotIDs: loopSlotIDs) else {
            return
        }
        onLoop(section)
    }
}

/// Fires a callback when playback reaches the end of an actively looping section.
struct SectionLoopMonitor: View {
    @Bindable private var audioEngine = AudioEngineManager.shared
    let activeLoopSection: ArrangementDisplaySection?
    let onLoop: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: audioEngine.currentTime) { _, time in
                guard let section = activeLoopSection else { return }
                guard time >= section.timelineEndSeconds else { return }
                onLoop()
            }
    }
}

/// Fires a callback when playback reaches a scheduled section-cue time.
struct SectionCueMonitor: View {
    @Bindable private var audioEngine = AudioEngineManager.shared
    let cuedSectionID: UUID?
    let cueFireTime: TimeInterval?
    let onFire: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: audioEngine.currentTime) { _, time in
                guard cueFireTime != nil, cuedSectionID != nil else { return }
                guard time >= cueFireTime! else { return }
                onFire()
            }
    }
}

/// Transport elapsed time that reads the host clock while playing.
struct TransportElapsedTimeLabel: View {
    @Bindable var audioEngine: AudioEngineManager
    let duration: TimeInterval

    var body: some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    timeLabel(audioEngine.livePlayheadTime())
                }
            } else {
                timeLabel(audioEngine.currentTime)
            }
        }
    }

    private func timeLabel(_ currentTime: TimeInterval) -> some View {
        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct TransportControls: View {
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    let duration: TimeInterval
    let onPlay: () -> Void
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .disabled(!isLoaded)

                Button(action: audioEngine.isPlaying ? onPause : onPlay) {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .disabled(!isLoaded)
            }

            TransportElapsedTimeLabel(audioEngine: audioEngine, duration: duration)
        }
    }
}
