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
        if time > 0 {
            let x = TimelineLayout.xPosition(
                for: min(time, safeDuration),
                duration: safeDuration,
                contentWidth: contentWidth
            )

            Rectangle()
                .fill(Color.orange)
                .frame(width: 2, height: height)
                .offset(x: x - 1)
        }
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
