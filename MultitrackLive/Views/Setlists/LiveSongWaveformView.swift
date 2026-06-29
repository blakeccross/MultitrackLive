import SwiftUI

enum ArrangementSectionPalette {
    private static let pairs: [(background: Color, accent: Color)] = [
        (Color(red: 0.75, green: 0.88, blue: 0.98), Color(red: 0.35, green: 0.55, blue: 0.85)),
        (Color(red: 0.98, green: 0.95, blue: 0.75), Color(red: 0.85, green: 0.72, blue: 0.25)),
        (Color(red: 0.98, green: 0.88, blue: 0.72), Color(red: 0.90, green: 0.55, blue: 0.20)),
        (Color(red: 0.95, green: 0.82, blue: 0.88), Color(red: 0.85, green: 0.35, blue: 0.55)),
        (Color(red: 0.78, green: 0.92, blue: 0.88), Color(red: 0.25, green: 0.65, blue: 0.60)),
        (Color(red: 0.88, green: 0.82, blue: 0.98), Color(red: 0.50, green: 0.35, blue: 0.85)),
    ]

    static func colors(for index: Int) -> (background: Color, accent: Color) {
        pairs[index % pairs.count]
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

    @State private var sourcePeaks: [Float] = []
    @State private var cachedDisplayPeaks: [Float] = []

    private let waveformHeight: CGFloat = 72

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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
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
                        .background(Color.white.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 4)
                        .padding(.top, 4)
                    }
                    .frame(width: segmentWidth, height: waveformHeight)
                    .overlay {
                        if isCued {
                            Rectangle()
                                .stroke(Color.yellow.opacity(cueFlashPhase ? 1 : 0.35), lineWidth: 2)
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
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1, height: waveformHeight)
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

    private let waveformHeight: CGFloat = 72
    private let laneSpacing: CGFloat = 24

    private var laneHeight: CGFloat {
        waveformHeight + 24
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            if viewportWidth > 0 {
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
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: laneHeight)
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

        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.songName)
                .font(isCurrent ? .subheadline.weight(.semibold) : .caption.weight(.medium))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: laneContentWidth, alignment: .leading)

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
        }
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
