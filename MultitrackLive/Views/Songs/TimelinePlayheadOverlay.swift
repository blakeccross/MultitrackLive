import SwiftUI

// MARK: - Playhead metrics

private enum PlayheadMetrics {
    static let handleWidth: CGFloat = 12
    static let handleBodyHeight: CGFloat = 9
    static let handleTipHeight: CGFloat = 5
    static let lineWidth: CGFloat = 1
    static let borderWidth: CGFloat = 1

    static var handleHeight: CGFloat { handleBodyHeight + handleTipHeight }
    static var lineTotalWidth: CGFloat { lineWidth + borderWidth * 2 }
}

// MARK: - Playhead clock

/// Drives playhead position from a single display-linked clock.
struct TimelinePlayheadTimeReader<Content: View>: View {
    @Bindable private var audioEngine = AudioEngineManager.shared
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        if audioEngine.isPlaying {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                content(audioEngine.livePlayheadTime())
            }
        } else {
            content(audioEngine.currentTime)
        }
    }
}

// MARK: - Playhead layer

/// Pins timeline content under a single playhead overlay so the handle and line stay in sync.
struct TimelinePlayheadLayer<Content: View>: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let displayWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelinePlayheadTimeReader { playheadTime in
            ZStack(alignment: .topLeading) {
                content()
                TimelinePlayheadOverlay(
                    playheadTime: playheadTime,
                    duration: duration,
                    contentWidth: contentWidth,
                    height: height
                )
            }
            .frame(width: displayWidth, alignment: .leading)
        }
    }
}

/// Logic Pro–style playhead drawn in one canvas pass with a shared pixel-aligned center.
struct TimelinePlayheadOverlay: View {
    @Environment(\.displayScale) private var displayScale

    let playheadTime: TimeInterval
    let duration: TimeInterval
    let contentWidth: CGFloat
    let height: CGFloat

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var clampedTime: TimeInterval {
        min(max(0, playheadTime), safeDuration)
    }

    var body: some View {
        Canvas { context, size in
            let centerX = pixelAligned(
                TimelineLayout.xPosition(
                    for: clampedTime,
                    duration: safeDuration,
                    contentWidth: contentWidth
                ),
                scale: displayScale
            )
            drawPlayhead(in: context, size: size, centerX: centerX)
        }
        .frame(width: contentWidth, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func drawPlayhead(in context: GraphicsContext, size: CGSize, centerX: CGFloat) {
        drawLine(in: context, size: size, centerX: centerX)
        drawHandle(in: context, centerX: centerX)
    }

    private func drawLine(in context: GraphicsContext, size: CGSize, centerX: CGFloat) {
        let lineTop = PlayheadMetrics.handleHeight
        let lineHeight = max(0, size.height - lineTop)
        guard lineHeight > 0 else { return }

        let lineLeft = pixelAligned(centerX - PlayheadMetrics.lineTotalWidth / 2, scale: displayScale)
        let borderRect = CGRect(
            x: lineLeft,
            y: lineTop,
            width: PlayheadMetrics.lineTotalWidth,
            height: lineHeight
        )
        context.fill(Path(borderRect), with: .color(.dawPlayheadBorder))

        let innerRect = CGRect(
            x: lineLeft + PlayheadMetrics.borderWidth,
            y: lineTop,
            width: PlayheadMetrics.lineWidth,
            height: lineHeight
        )
        context.fill(Path(innerRect), with: .color(.dawPlayheadFill))
    }

    private func drawHandle(in context: GraphicsContext, centerX: CGFloat) {
        let handleLeft = pixelAligned(centerX - PlayheadMetrics.handleWidth / 2, scale: displayScale)
        let handleRect = CGRect(
            x: handleLeft,
            y: 0,
            width: PlayheadMetrics.handleWidth,
            height: PlayheadMetrics.handleHeight
        )
        let handlePath = playheadHandlePath(in: handleRect)

        context.fill(handlePath, with: .color(.dawPlayheadFill))
        context.stroke(
            handlePath,
            with: .color(.dawPlayheadBorder),
            style: StrokeStyle(lineWidth: PlayheadMetrics.borderWidth)
        )
    }

    private func playheadHandlePath(in rect: CGRect) -> Path {
        let bodyBottom = rect.height * (PlayheadMetrics.handleBodyHeight / PlayheadMetrics.handleHeight)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bodyBottom))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bodyBottom))
        path.closeSubpath()
        return path
    }

    private func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value.rounded(.toNearestOrAwayFromZero) }
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
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
            .foregroundStyle(AppColors.textSecondary)
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}