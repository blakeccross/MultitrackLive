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

    static let horizontalZoomAppStorageKey = "liveSetlistWaveformHorizontalZoom"
    static let defaultHorizontalZoom: CGFloat = 1
    static let defaultHorizontalZoomStorageValue = Double(defaultHorizontalZoom)
    static let minimumHorizontalZoom: CGFloat = 1
    static let maximumHorizontalZoom: CGFloat = 3

    static func clampedWaveformHeight(_ height: CGFloat) -> CGFloat {
        min(maximumWaveformHeight, max(minimumWaveformHeight, height))
    }

    static func waveformHeight(fromStorage value: Double) -> CGFloat {
        clampedWaveformHeight(CGFloat(value))
    }

    static func storageValue(forHeight waveformHeight: CGFloat) -> Double {
        Double(clampedWaveformHeight(waveformHeight))
    }

    static func laneHeight(for waveformHeight: CGFloat) -> CGFloat {
        clampedWaveformHeight(waveformHeight) + laneVerticalPadding
    }

    static func clampedHorizontalZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumHorizontalZoom, max(minimumHorizontalZoom, zoom))
    }

    static func horizontalZoom(fromStorage value: Double) -> CGFloat {
        clampedHorizontalZoom(CGFloat(value))
    }

    static func storageValue(forZoom horizontalZoom: CGFloat) -> Double {
        Double(clampedHorizontalZoom(horizontalZoom))
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
        storedWaveformHeight = LiveSetlistWaveformMetrics.storageValue(forHeight: waveformHeight)
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
    let peakSections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    var showsPlayhead = true
    var isInteractive = true
    var playheadTimeProvider: (() -> TimeInterval)?
    var isPlayingProvider: (() -> Bool)?
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void

    @Bindable private var audioEngine = AudioEngineManager.shared

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    @State private var sourcePeaks: [Float] = []
    @State private var cachedDisplayPeaks: [Float] = []

    private static let unplayedWaveformOpacity: Double = 0.32

    private var safeTimelineDuration: TimeInterval {
        max(timelineDuration, 0.001)
    }

    private var usesArrangementLayout: Bool {
        !sections.isEmpty
    }

    private var usesArrangedPeakMapping: Bool {
        !peakSections.isEmpty
    }

    private var showsFullSourceWaveform: Bool {
        !usesArrangementLayout || !usesArrangedPeakMapping
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

            measureGrid(contentWidth: contentWidth)

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
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .modifier(WaveformSeekGestureModifier(
            isEnabled: isInteractive,
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
        .onChange(of: peakSections.map(\.id)) { _, _ in
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
                    .fill(Color.liveVoiceMemosBackground)
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
                            .fill(palette.background.opacity(isCued && cueFlashPhase ? 0.55 : 0.35))

                        sectionWaveform(
                            for: section,
                            segmentWidth: segmentWidth
                        )

                        HStack(spacing: 3) {
                            if isLoopSection {
                                Image(systemName: "repeat")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(palette.accent)
                            }
                            Text(section.name.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                    .fill(Color.liveVoiceMemosBackground)

                if !cachedDisplayPeaks.isEmpty || isLoadingWaveform {
                    playbackAwareWaveform(
                        bars: cachedDisplayPeaks,
                        showsEmptyBaseline: isLoadingWaveform || showsFullSourceWaveform,
                        width: contentWidth,
                        timelineStart: 0,
                        timelineEnd: safeTimelineDuration
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func sectionWaveform(
        for section: ArrangementDisplaySection,
        segmentWidth: CGFloat
    ) -> some View {
        if !cachedDisplayPeaks.isEmpty || isLoadingWaveform {
            playbackAwareWaveform(
                bars: sectionDisplayPeaks(
                    timelineStart: section.timelineStartSeconds,
                    timelineEnd: section.timelineEndSeconds
                ),
                showsEmptyBaseline: isLoadingWaveform || showsFullSourceWaveform,
                width: segmentWidth,
                timelineStart: section.timelineStartSeconds,
                timelineEnd: section.timelineEndSeconds
            )
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
    /// Draws the waveform bars with a Voice Memos–style progress treatment: the
    /// unplayed portion is dimmed and the played portion (left of the playhead)
    /// is revealed at full opacity via an animated mask.
    @ViewBuilder
    private func playbackAwareWaveform(
        bars: [Float],
        showsEmptyBaseline: Bool,
        width: CGFloat,
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval
    ) -> some View {
        ZStack(alignment: .leading) {
            waveformBarsLayer(
                bars: bars,
                showsEmptyBaseline: showsEmptyBaseline,
                fillColor: .white.opacity(Self.unplayedWaveformOpacity)
            )

            if showsPlayhead {
                waveformBarsLayer(
                    bars: bars,
                    showsEmptyBaseline: showsEmptyBaseline,
                    fillColor: .white
                )
                .mask(alignment: .leading) {
                    playedProgressMask(
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd,
                        width: width
                    )
                }
            }
        }
        .frame(width: width, height: waveformHeight)
        .allowsHitTesting(false)
    }

    private func waveformBarsLayer(
        bars: [Float],
        showsEmptyBaseline: Bool,
        fillColor: Color
    ) -> some View {
        WaveformBarsCanvas(
            bars: bars,
            showsEmptyBaseline: showsEmptyBaseline,
            fillColor: fillColor,
            style: .voiceMemosBars
        )
    }

    @ViewBuilder
    private func playedProgressMask(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        width: CGFloat
    ) -> some View {
        if resolvedIsPlaying {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                playedMaskRect(
                    width: playedWidth(
                        timelineStart: timelineStart,
                        timelineEnd: timelineEnd,
                        segmentWidth: width,
                        time: resolvedPlayheadTime(live: true)
                    )
                )
            }
        } else {
            playedMaskRect(
                width: playedWidth(
                    timelineStart: timelineStart,
                    timelineEnd: timelineEnd,
                    segmentWidth: width,
                    time: resolvedPlayheadTime(live: false)
                )
            )
        }
    }

    private func playedMaskRect(width: CGFloat) -> some View {
        Rectangle()
            .frame(width: max(0, width))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func playedWidth(
        timelineStart: TimeInterval,
        timelineEnd: TimeInterval,
        segmentWidth: CGFloat,
        time: TimeInterval
    ) -> CGFloat {
        let span = max(0.0001, timelineEnd - timelineStart)
        let fraction = (time - timelineStart) / span
        return min(max(0, CGFloat(fraction)), 1) * segmentWidth
    }

    private func measureGrid(contentWidth: CGFloat) -> some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, !tempoChanges.isEmpty else { return }

            let measureBoundaries = MeasureTiming.visibleMeasureBoundaries(
                duration: safeTimelineDuration,
                tempoChanges: tempoChanges,
                contentWidth: contentWidth,
                timeSignatureChanges: timeSignatureChanges
            )

            let beatLineColor = Color.white.opacity(0.22)
            let measureLineColor = Color.white.opacity(0.65)

            if shouldShowBeatLines(contentWidth: contentWidth) {
                for time in beatBoundaries() {
                    strokeGridLine(
                        at: time,
                        contentWidth: contentWidth,
                        size: size,
                        color: beatLineColor,
                        in: context
                    )
                }
            }

            for time in measureBoundaries {
                strokeGridLine(
                    at: time,
                    contentWidth: contentWidth,
                    size: size,
                    color: measureLineColor,
                    in: context
                )
            }
        }
        .frame(width: contentWidth, height: waveformHeight)
        .allowsHitTesting(false)
    }

    private func shouldShowBeatLines(contentWidth: CGFloat) -> Bool {
        let bpm = MeasureTiming.bpmForMeasure(1, tempoChanges: tempoChanges)
        let signature = MeasureTiming.numeratorDenominatorForMeasure(1, changes: timeSignatureChanges)
        let beatsInMeasure = MeasureTiming.beatsPerMeasure(
            numerator: signature.numerator,
            denominator: signature.denominator
        )
        guard beatsInMeasure > 0 else { return false }

        let beatDuration = MeasureTiming.measureDuration(
            bpm: bpm,
            numerator: signature.numerator,
            denominator: signature.denominator
        ) / beatsInMeasure
        let pixelsPerBeat = CGFloat(beatDuration) * contentWidth / CGFloat(safeTimelineDuration)
        return pixelsPerBeat >= 8
    }

    private func beatBoundaries() -> [TimeInterval] {
        var times: [TimeInterval] = []
        var measure = 1

        while measure < 1_000_000 {
            let measureStart = MeasureTiming.timeAtStartOfMeasure(
                measure,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges
            )
            guard measureStart < safeTimelineDuration - 0.0001 else { break }

            let bpm = MeasureTiming.bpmForMeasure(measure, tempoChanges: tempoChanges)
            let signature = MeasureTiming.numeratorDenominatorForMeasure(
                measure,
                changes: timeSignatureChanges
            )
            let beatsInMeasure = MeasureTiming.beatsPerMeasure(
                numerator: signature.numerator,
                denominator: signature.denominator
            )
            let measureDuration = MeasureTiming.measureDuration(
                bpm: bpm,
                numerator: signature.numerator,
                denominator: signature.denominator
            )
            guard beatsInMeasure > 0, measureDuration > 0 else {
                measure += 1
                continue
            }

            let beatDuration = measureDuration / beatsInMeasure
            let beatCount = max(0, Int(beatsInMeasure.rounded(.down)))
            for beatIndex in 1..<beatCount {
                let time = measureStart + TimeInterval(beatIndex) * beatDuration
                guard time < safeTimelineDuration - 0.0001 else { break }
                times.append(time)
            }

            measure += 1
        }

        return times
    }

    private static let gridLineVerticalInset: CGFloat = 8
    private static let gridLineWidth: CGFloat = 1

    private func strokeGridLine(
        at time: TimeInterval,
        contentWidth: CGFloat,
        size: CGSize,
        color: Color,
        in context: GraphicsContext
    ) {
        let x = TimelineLayout.xPosition(
            for: time,
            duration: safeTimelineDuration,
            contentWidth: contentWidth
        )
        guard x >= 0, x <= size.width else { return }

        let inset = min(Self.gridLineVerticalInset, size.height / 2)
        let height = max(0, size.height - inset * 2)
        let rect = CGRect(
            x: (x - Self.gridLineWidth / 2).rounded(),
            y: inset,
            width: Self.gridLineWidth,
            height: height
        )
        context.fill(Path(rect), with: .color(color))
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
            if resolvedIsPlaying {
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

    private var resolvedIsPlaying: Bool {
        if let isPlayingProvider {
            return isPlayingProvider()
        }
        return audioEngine.isPlaying
    }

    @ViewBuilder
    private func playheadMarker(at time: TimeInterval, contentWidth: CGFloat) -> some View {
        let x = TimelineLayout.xPosition(
            for: min(time, safeTimelineDuration),
            duration: safeTimelineDuration,
            contentWidth: contentWidth
        )

        Rectangle()
            .fill(Color.white.opacity(0.92))
            .frame(width: 2, height: waveformHeight)
            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0)
            .offset(x: x - 1)
    }

    private func refreshDisplayPeaks(contentWidth: CGFloat) {
        guard contentWidth > 0 else { return }

        if showsFullSourceWaveform {
            cachedDisplayPeaks = WaveformPeakResampler.displayPeaks(
                from: sourcePeaks,
                contentWidth: contentWidth,
                minimumBarSlotWidth: WaveformPeakResampler.voiceMemosBarSlotWidth
            )
        } else {
            cachedDisplayPeaks = WaveformPeakResampler.arrangedDisplayPeaks(
                from: sourcePeaks,
                fileDuration: fileDuration,
                sections: peakSections,
                timelineDuration: safeTimelineDuration,
                contentWidth: contentWidth,
                minimumBarSlotWidth: WaveformPeakResampler.voiceMemosBarSlotWidth
            )
        }
    }
}

struct SetlistWaveformHeaderMarker: View {
    let title: String

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    private var laneHeight: CGFloat {
        LiveSetlistWaveformMetrics.laneHeight(for: waveformHeight)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(AppColors.backgroundPrimary)
            .overlay {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: laneHeight - AppSpacing.md)
            }
            .frame(width: 40, height: laneHeight)
    }
}

struct LiveSetlistWaveformScrollView: View {
    let timelineItems: [LiveSetlistTimelineItem]
    let currentPlaybackIndex: Int
    let songForID: (UUID) -> Song?
    let waveformSnapshotForSong: (Song) -> LiveSongWaveformSnapshot?
    let ensureWaveformSnapshot: (Song) -> Void
    let playheadTimeProvider: () -> TimeInterval
    let isPlayingProvider: () -> Bool
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void
    var onOverlapBadgeTapped: ((Int) -> Void)?

    @AppStorage(LiveSetlistWaveformMetrics.horizontalZoomAppStorageKey)
    private var storedHorizontalZoom = LiveSetlistWaveformMetrics.defaultHorizontalZoomStorageValue

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    @State private var viewportWidth: CGFloat = 1
    @State private var horizontalZoom = LiveSetlistWaveformMetrics.defaultHorizontalZoom
    @State private var pinchStartZoom: CGFloat?

    private let laneSpacing: CGFloat = 24
    private static let zoomAdjustmentStep: CGFloat = 0.25

    private var laneHeight: CGFloat {
        LiveSetlistWaveformMetrics.laneHeight(for: waveformHeight)
    }

    private var currentSongScrollID: String {
        "song-\(currentPlaybackIndex)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: laneSpacing) {
                    ForEach(timelineItems) { item in
                        timelineItemView(item)
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
            .onChange(of: currentPlaybackIndex) { _, _ in
                scrollToCurrent(proxy)
            }
        }
        .simultaneousGesture(horizontalPinchGesture)
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
        .animation(.none, value: horizontalZoom)
        .onAppear {
            horizontalZoom = LiveSetlistWaveformMetrics.horizontalZoom(fromStorage: storedHorizontalZoom)
        }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                setHorizontalZoom(horizontalZoom + Self.zoomAdjustmentStep)
            case .decrement:
                setHorizontalZoom(horizontalZoom - Self.zoomAdjustmentStep)
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func timelineItemView(_ item: LiveSetlistTimelineItem) -> some View {
        switch item {
        case .header(_, let title):
            SetlistWaveformHeaderMarker(title: title)
                .id(item.id)

        case .song(let songID, let playbackIndex, let transitionAfter):
            if let song = songForID(songID) {
                HStack(alignment: .top, spacing: laneSpacing) {
                    songLane(for: song, playbackIndex: playbackIndex)
                        .id(item.id)

                    if let transitionAfter {
                        transitionBadge(transitionAfter, playbackIndex: playbackIndex)
                    }
                }
            }
        }
    }

    private func transitionBadge(_ transition: SetlistTransition, playbackIndex: Int) -> some View {
        VStack {
            Spacer()
            SetlistTransitionBadge(
                transition: transition,
                onTap: transition == .overlap
                    ? { onOverlapBadgeTapped?(playbackIndex) }
                    : nil
            )
            Spacer()
        }
        .frame(height: laneHeight)
    }

    private var horizontalPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStartZoom == nil {
                    pinchStartZoom = horizontalZoom
                }
                guard let pinchStartZoom else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    horizontalZoom = LiveSetlistWaveformMetrics.clampedHorizontalZoom(pinchStartZoom * scale)
                }
            }
            .onEnded { _ in
                pinchStartZoom = nil
                persistHorizontalZoom()
            }
    }

    private func setHorizontalZoom(_ proposed: CGFloat) {
        horizontalZoom = LiveSetlistWaveformMetrics.clampedHorizontalZoom(proposed)
        persistHorizontalZoom()
    }

    private func persistHorizontalZoom() {
        storedHorizontalZoom = LiveSetlistWaveformMetrics.storageValue(forZoom: horizontalZoom)
    }

    private func laneContentWidth(for snapshot: LiveSongWaveformSnapshot) -> CGFloat {
        let fitWidth = max(
            viewportWidth,
            TimelineLayout.contentWidth(for: snapshot.timelineDuration, zoom: 1)
        )
        return fitWidth * horizontalZoom
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(currentSongScrollID, anchor: .leading)
        }
    }

    @ViewBuilder
    private func songLane(for song: Song, playbackIndex: Int) -> some View {
        let isCurrent = playbackIndex == currentPlaybackIndex

        if let snapshot = waveformSnapshotForSong(song) {
            waveformLane(snapshot: snapshot, isCurrent: isCurrent)
        } else {
            LiveSetlistWaveformLanePlaceholder(isCurrent: isCurrent)
                .task(id: song.id) {
                    ensureWaveformSnapshot(song)
                }
        }
    }

    @ViewBuilder
    private func waveformLane(
        snapshot: LiveSongWaveformSnapshot,
        isCurrent: Bool
    ) -> some View {
        let laneContentWidth = laneContentWidth(for: snapshot)

        LiveSongWaveformView(
            contentWidth: laneContentWidth,
            trackSources: snapshot.trackSources,
            fileDuration: snapshot.fileDuration,
            timelineDuration: snapshot.timelineDuration,
            sections: snapshot.sections,
            peakSections: snapshot.peakSections,
            loopSlotIDs: snapshot.loopSlotIDs,
            tempoChanges: snapshot.tempoChanges,
            timeSignatureChanges: snapshot.timeSignatureChanges,
            cuedSectionID: isCurrent ? cuedSectionID : nil,
            cueFlashPhase: isCurrent ? cueFlashPhase : false,
            showsPlayhead: isCurrent,
            isInteractive: isCurrent,
            playheadTimeProvider: isCurrent ? playheadTimeProvider : nil,
            isPlayingProvider: isCurrent ? isPlayingProvider : nil,
            onSeek: onSeek,
            onCueSection: onCueSection
        )
        .opacity(isCurrent ? 1 : 0.72)
    }
}

private struct LiveSetlistWaveformLanePlaceholder: View {
    let isCurrent: Bool

    @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

    private var laneHeight: CGFloat {
        LiveSetlistWaveformMetrics.laneHeight(for: waveformHeight)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
            .fill(AppColors.backgroundPrimary)
            .frame(width: 180, height: laneHeight)
            .opacity(isCurrent ? 1 : 0.72)
            .overlay {
                ProgressView()
                    .controlSize(.small)
            }
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
