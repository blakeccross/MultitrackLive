import SwiftUI
#if os(macOS)
import AppKit
#endif

enum ArrangementSectionPalette {
    private static let pairs: [(background: Color, accent: Color)] = [
        (Color(red: 0.22, green: 0.26, blue: 0.32), Color(red: 0.42, green: 0.52, blue: 0.68)),
        (Color(red: 0.28, green: 0.26, blue: 0.18), Color(red: 0.62, green: 0.52, blue: 0.22)),
        (Color(red: 0.30, green: 0.22, blue: 0.16), Color(red: 0.68, green: 0.42, blue: 0.22)),
        (Color(red: 0.28, green: 0.18, blue: 0.22), Color(red: 0.62, green: 0.32, blue: 0.42)),
        (Color(red: 0.16, green: 0.26, blue: 0.26), Color(red: 0.28, green: 0.52, blue: 0.48)),
        (Color(red: 0.22, green: 0.18, blue: 0.30), Color(red: 0.48, green: 0.36, blue: 0.68)),
    ]

    static func colors(for index: Int) -> (background: Color, accent: Color) {
        pairs[index % pairs.count]
    }
}

enum LiveSetlistWaveformMetrics {
    static let appStorageKey = "liveSetlistWaveformHeight"
    static let defaultWaveformHeight: CGFloat = 96
    static let defaultWaveformHeightStorageValue = Double(defaultWaveformHeight)
    static let minimumWaveformHeight: CGFloat = 56
    static let maximumWaveformHeight: CGFloat = 200
    static let laneVerticalPadding: CGFloat = 24

    static func clampedWaveformHeight(_ height: CGFloat) -> CGFloat {
        min(maximumWaveformHeight, max(minimumWaveformHeight, height))
    }

    static func waveformHeight(fromStorage value: Double) -> CGFloat {
        clampedWaveformHeight(CGFloat(value))
    }

    static func storageValue(for waveformHeight: CGFloat) -> Double {
        Double(clampedWaveformHeight(waveformHeight))
    }

    static func laneHeight(for waveformHeight: CGFloat) -> CGFloat {
        clampedWaveformHeight(waveformHeight) + laneVerticalPadding
    }
}

private struct LiveSetlistWaveformHeightKey: EnvironmentKey {
    static let defaultValue = LiveSetlistWaveformMetrics.defaultWaveformHeight
}

extension EnvironmentValues {
    var liveSetlistWaveformHeight: CGFloat {
        get { self[LiveSetlistWaveformHeightKey.self] }
        set { self[LiveSetlistWaveformHeightKey.self] = newValue }
    }
}

struct LiveSetlistWaveformResizablePanel<Content: View>: View {
    @AppStorage(LiveSetlistWaveformMetrics.appStorageKey)
    private var storedWaveformHeight = LiveSetlistWaveformMetrics.defaultWaveformHeightStorageValue

    @State private var waveformHeight = LiveSetlistWaveformMetrics.defaultWaveformHeight

    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .environment(\.liveSetlistWaveformHeight, waveformHeight)

            LiveSetlistWaveformResizeHandle(
                height: $waveformHeight,
                onResizeEnded: persistWaveformHeight
            )
        }
        .animation(.none, value: waveformHeight)
        .onAppear {
            waveformHeight = LiveSetlistWaveformMetrics.waveformHeight(fromStorage: storedWaveformHeight)
        }
    }

    private func persistWaveformHeight() {
        storedWaveformHeight = LiveSetlistWaveformMetrics.storageValue(for: waveformHeight)
    }
}

private struct LiveSetlistWaveformResizeHandle: View {
    @Binding var height: CGFloat
    let onResizeEnded: () -> Void

    @State private var dragStartHeight: CGFloat?

    private static let hitAreaHeight: CGFloat = 20
    private static let adjustmentStep: CGFloat = 8

    var body: some View {
        ZStack {
            Color.clear

            Capsule()
                .fill(AppColors.textTertiary.opacity(0.5))
                .frame(width: 44, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.hitAreaHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = height
                    }
                    let proposed = (dragStartHeight ?? height) + value.translation.height
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        height = LiveSetlistWaveformMetrics.clampedWaveformHeight(proposed)
                    }
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    onResizeEnded()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveform height")
        .accessibilityValue("\(Int(LiveSetlistWaveformMetrics.clampedWaveformHeight(height))) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                height = LiveSetlistWaveformMetrics.clampedWaveformHeight(height + Self.adjustmentStep)
            case .decrement:
                height = LiveSetlistWaveformMetrics.clampedWaveformHeight(height - Self.adjustmentStep)
            @unknown default:
                break
            }
            onResizeEnded()
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.resizeUpDown.push()
            case .ended:
                NSCursor.pop()
            }
        }
        #endif
    }
}

struct LiveSongWaveformView: View {
    let contentWidth: CGFloat
    let trackSources: [(url: URL, duration: TimeInterval)]
    let fileDuration: TimeInterval
    let timelineDuration: TimeInterval
    let sections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    var showsPlayhead = true
    var isInteractive = true
    var playheadTimeProvider: (() -> TimeInterval)?
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void

    @Bindable private var audioEngine = AudioEngineManager.shared

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    @State private var sourcePeaks: [Float] = []
    @State private var cachedDisplayPeaks: [Float] = []

    private var safeTimelineDuration: TimeInterval {
        max(timelineDuration, 0.001)
    }

    private var usesArrangementLayout: Bool {
        !sections.isEmpty
    }

    private var usesSourceLinearTimeline: Bool {
        sections.usesSourceLinearTimeline
    }

    private var showsFullSourceWaveform: Bool {
        !usesArrangementLayout || usesSourceLinearTimeline
    }

    private var trackSourcesKey: String {
        trackSources
            .map { "\($0.url.path)|\($0.duration)" }
            .joined(separator: ";")
    }

    private var isLoadingWaveform: Bool {
        !trackSources.isEmpty && cachedDisplayPeaks.isEmpty
    }

    var body: some View {
        ZStack(alignment: .leading) {
            sectionBackgrounds(contentWidth: contentWidth)

            if isInteractive {
                sectionTapTargets(contentWidth: contentWidth)
            }

            if showsPlayhead {
                playhead(contentWidth: contentWidth)
            }
        }
        .frame(width: contentWidth, height: waveformHeight)
        .animation(.none, value: waveformHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppColors.separator, lineWidth: 0.5)
        }
        .modifier(WaveformSeekGestureModifier(
            isEnabled: isInteractive && (!usesArrangementLayout || usesSourceLinearTimeline),
            contentWidth: contentWidth,
            duration: safeTimelineDuration,
            onSeek: onSeek
        ))
        .onAppear {
            refreshDisplayPeaks(contentWidth: contentWidth)
        }
        .onChange(of: contentWidth) { _, newWidth in
            refreshDisplayPeaks(contentWidth: newWidth)
        }
        .onChange(of: sourcePeaks.count) { _, _ in
            refreshDisplayPeaks(contentWidth: contentWidth)
        }
        .onChange(of: sections.map(\.id)) { _, _ in
            refreshDisplayPeaks(contentWidth: contentWidth)
        }
        .task(id: trackSourcesKey) {
            guard !trackSources.isEmpty else {
                sourcePeaks = []
                return
            }
            if let cached = WaveformCache.shared.cachedSummedPeaks(for: trackSources) {
                sourcePeaks = cached
            } else {
                sourcePeaks = await WaveformCache.shared.summedPeaks(for: trackSources)
            }
            refreshDisplayPeaks(contentWidth: contentWidth)
        }
    }

    @ViewBuilder
    private func sectionBackgrounds(contentWidth: CGFloat) -> some View {
        if usesArrangementLayout {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.dawLaneBackground)
                    .frame(width: contentWidth, height: waveformHeight)

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let startX = TimelineLayout.xPosition(
                        for: section.timelineStartSeconds,
                        duration: safeTimelineDuration,
                        contentWidth: contentWidth
                    )
                    let endX = TimelineLayout.xPosition(
                        for: section.timelineEndSeconds,
                        duration: safeTimelineDuration,
                        contentWidth: contentWidth
                    )
                    let segmentWidth = max(0, endX - startX)
                    let palette = ArrangementSectionPalette.colors(for: index)
                    let isCued = cuedSectionID == section.id
                    let isLoopSection = loopSlotIDs.contains(section.id)

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(palette.background.opacity(isCued && cueFlashPhase ? 1 : 0.85))

                        sectionWaveform(
                            for: section,
                            accentColor: palette.accent,
                            segmentWidth: segmentWidth
                        )

                        HStack(spacing: 3) {
                            if isLoopSection {
                                Image(systemName: "repeat")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(palette.accent)
                            }
                            Text(section.name)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.accent)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AppColors.surfaceElevated.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                        .padding(.leading, 4)
                        .padding(.top, 4)
                    }
                    .frame(width: segmentWidth, height: waveformHeight)
                    .overlay {
                        if isCued {
                            Rectangle()
                                .stroke(AppColors.accent.opacity(cueFlashPhase ? 1 : 0.35), lineWidth: 2)
                        }
                    }
                    .offset(x: startX)
                }

                ForEach(sections) { section in
                    let x = TimelineLayout.xPosition(
                        for: section.timelineStartSeconds,
                        duration: safeTimelineDuration,
                        contentWidth: contentWidth
                    )
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(width: 0.5, height: waveformHeight)
                        .offset(x: x)
                }
            }
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.dawLaneBackground)

                if !cachedDisplayPeaks.isEmpty || isLoadingWaveform {
                    WaveformBarsCanvas(
                        bars: cachedDisplayPeaks,
                        showsEmptyBaseline: isLoadingWaveform || showsFullSourceWaveform
                    )
                    .frame(width: contentWidth, height: waveformHeight)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionWaveform(
        for section: ArrangementDisplaySection,
        accentColor: Color,
        segmentWidth: CGFloat
    ) -> some View {
        if !cachedDisplayPeaks.isEmpty || isLoadingWaveform {
            WaveformBarsCanvas(
                bars: sectionDisplayPeaks(
                    timelineStart: section.timelineStartSeconds,
                    timelineEnd: section.timelineEndSeconds
                ),
                showsEmptyBaseline: isLoadingWaveform || showsFullSourceWaveform,
                fillColor: accentColor.opacity(0.82)
            )
            .frame(width: segmentWidth, height: waveformHeight)
            .allowsHitTesting(false)
        }
    }

    private func sectionDisplayPeaks(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> [Float] {
        WaveformPeakResampler.peaksSlice(
            from: cachedDisplayPeaks,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            timelineDuration: safeTimelineDuration
        )
    }

    @ViewBuilder
    private func sectionTapTargets(contentWidth: CGFloat) -> some View {
        if usesArrangementLayout {
            ZStack(alignment: .leading) {
                ForEach(sections) { section in
                    let startX = TimelineLayout.xPosition(
                        for: section.timelineStartSeconds,
                        duration: safeTimelineDuration,
                        contentWidth: contentWidth
                    )
                    let endX = TimelineLayout.xPosition(
                        for: section.timelineEndSeconds,
                        duration: safeTimelineDuration,
                        contentWidth: contentWidth
                    )
                    let segmentWidth = max(0, endX - startX)

                    Color.clear
                        .frame(width: segmentWidth, height: waveformHeight)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onCueSection(section)
                        }
                        .contextMenu {
                            Button("Cue Section") {
                                onCueSection(section)
                            }
                        }
                        .offset(x: startX)
                }
            }
        }
    }

    @ViewBuilder
    private func playhead(contentWidth: CGFloat) -> some View {
        Group {
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    playheadMarker(
                        at: resolvedPlayheadTime(live: true),
                        contentWidth: contentWidth
                    )
                }
            } else {
                playheadMarker(
                    at: resolvedPlayheadTime(live: false),
                    contentWidth: contentWidth
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func resolvedPlayheadTime(live: Bool) -> TimeInterval {
        if let playheadTimeProvider {
            return playheadTimeProvider()
        }
        return live ? audioEngine.livePlayheadTime() : audioEngine.currentTime
    }

    @ViewBuilder
    private func playheadMarker(at time: TimeInterval, contentWidth: CGFloat) -> some View {
        let x = TimelineLayout.xPosition(
            for: min(time, safeTimelineDuration),
            duration: safeTimelineDuration,
            contentWidth: contentWidth
        )

        ZStack {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: waveformHeight)

            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        }
        .offset(x: x - 1)
    }

    private func refreshDisplayPeaks(contentWidth: CGFloat) {
        guard contentWidth > 0 else { return }

        if showsFullSourceWaveform {
            cachedDisplayPeaks = WaveformPeakResampler.displayPeaks(
                from: sourcePeaks,
                contentWidth: contentWidth
            )
        } else {
            cachedDisplayPeaks = WaveformPeakResampler.arrangedDisplayPeaks(
                from: sourcePeaks,
                fileDuration: fileDuration,
                sections: sections,
                timelineDuration: safeTimelineDuration,
                contentWidth: contentWidth
            )
        }
    }
}

struct LiveSetlistWaveformScrollView: View {
    let currentSnapshot: LiveSongWaveformSnapshot
    let nextSnapshot: LiveSongWaveformSnapshot?
    let transitionToNext: SetlistTransition?
    let playheadTimeProvider: () -> TimeInterval
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    @State private var viewportWidth: CGFloat = 1

    private let laneSpacing: CGFloat = 24

    private var laneHeight: CGFloat {
        LiveSetlistWaveformMetrics.laneHeight(for: waveformHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: laneSpacing) {
                    waveformLane(
                        snapshot: currentSnapshot,
                        isCurrent: true,
                        scrollID: "current"
                    )

                    if let nextSnapshot {
                        if let transitionToNext {
                            VStack {
                                Spacer()
                                SetlistTransitionBadge(transition: transitionToNext)
                                Spacer()
                            }
                            .frame(height: laneHeight)
                        }

                        waveformLane(
                            snapshot: nextSnapshot,
                            isCurrent: false,
                            scrollID: "next"
                        )
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 2)
                .frame(minWidth: viewportWidth, alignment: .leading)
            }
            .defaultScrollAnchor(.leading)
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                scrollToCurrent(proxy)
            }
            .onChange(of: currentSnapshot.songID) { _, _ in
                scrollToCurrent(proxy)
            }
            .onChange(of: nextSnapshot?.songID) { _, _ in
                scrollToCurrent(proxy)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width, initial: true) { _, width in
                        viewportWidth = max(width, 1)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: laneHeight)
        .animation(.none, value: waveformHeight)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("current", anchor: .leading)
        }
    }

    @ViewBuilder
    private func waveformLane(
        snapshot: LiveSongWaveformSnapshot,
        isCurrent: Bool,
        scrollID: String
    ) -> some View {
        let laneContentWidth = snapshot.contentWidth

        LiveSongWaveformView(
            contentWidth: laneContentWidth,
            trackSources: snapshot.trackSources,
            fileDuration: snapshot.fileDuration,
            timelineDuration: snapshot.timelineDuration,
            sections: snapshot.sections,
            loopSlotIDs: snapshot.loopSlotIDs,
            cuedSectionID: isCurrent ? cuedSectionID : nil,
            cueFlashPhase: isCurrent ? cueFlashPhase : false,
            showsPlayhead: isCurrent,
            isInteractive: isCurrent,
            playheadTimeProvider: isCurrent ? playheadTimeProvider : nil,
            onSeek: onSeek,
            onCueSection: onCueSection
        )
        .id(scrollID)
        .opacity(isCurrent ? 1 : 0.72)
    }
}

private struct WaveformSeekGestureModifier: ViewModifier {
    let isEnabled: Bool
    let contentWidth: CGFloat
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let time = TimelineLayout.time(
                            at: value.location.x,
                            duration: duration,
                            contentWidth: contentWidth
                        )
                        onSeek(time)
                    }
            )
        } else {
            content
        }
    }
}
