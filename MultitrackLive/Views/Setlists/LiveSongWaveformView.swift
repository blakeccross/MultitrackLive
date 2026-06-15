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
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    var showsPlayhead = true
    var isInteractive = true
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

    private var trackSourcesKey: String {
        trackSources
            .map { "\($0.url.path)|\($0.duration)" }
            .joined(separator: ";")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            sectionBackgrounds(contentWidth: contentWidth)

            if !cachedDisplayPeaks.isEmpty {
                LiveSectionWaveformCanvas(
                    bars: cachedDisplayPeaks,
                    sections: sections,
                    timelineDuration: safeTimelineDuration,
                    contentWidth: contentWidth
                )
                .frame(width: contentWidth, height: waveformHeight)
                .allowsHitTesting(false)
            }

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
            isEnabled: isInteractive && !usesArrangementLayout,
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

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(palette.background.opacity(isCued && cueFlashPhase ? 1 : 0.85))

                        Text(section.name)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.accent)
                            .lineLimit(1)
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
            Rectangle()
                .fill(Color.dawLaneBackground)
        }
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
                        at: audioEngine.livePlayheadTime(),
                        contentWidth: contentWidth
                    )
                }
            } else {
                playheadMarker(
                    at: audioEngine.currentTime,
                    contentWidth: contentWidth
                )
            }
        }
        .allowsHitTesting(false)
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

        if usesArrangementLayout {
            cachedDisplayPeaks = WaveformPeakResampler.arrangedDisplayPeaks(
                from: sourcePeaks,
                fileDuration: fileDuration,
                sections: sections,
                timelineDuration: safeTimelineDuration,
                contentWidth: contentWidth
            )
        } else {
            cachedDisplayPeaks = WaveformPeakResampler.displayPeaks(
                from: sourcePeaks,
                contentWidth: contentWidth
            )
        }
    }
}

struct LiveSetlistWaveformScrollView: View {
    let currentSnapshot: LiveSongWaveformSnapshot
    let nextSnapshot: LiveSongWaveformSnapshot?
    let playbackDuration: TimeInterval
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: laneSpacing) {
                    waveformLane(
                        snapshot: currentSnapshot,
                        isCurrent: true,
                        scrollID: "current"
                    )

                    if let nextSnapshot {
                        waveformLane(
                            snapshot: nextSnapshot,
                            isCurrent: false,
                            scrollID: "next"
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                proxy.scrollTo("current", anchor: .leading)
            }
            .onChange(of: currentSnapshot.songID) { _, _ in
                proxy.scrollTo("current", anchor: .leading)
            }
        }
        .frame(height: laneHeight)
    }

    @ViewBuilder
    private func waveformLane(
        snapshot: LiveSongWaveformSnapshot,
        isCurrent: Bool,
        scrollID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.songName)
                .font(isCurrent ? .subheadline.weight(.semibold) : .caption.weight(.medium))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: snapshot.contentWidth, alignment: .leading)

            LiveSongWaveformView(
                contentWidth: snapshot.contentWidth,
                trackSources: snapshot.trackSources,
                fileDuration: snapshot.fileDuration,
                timelineDuration: isCurrent ? playbackDuration : snapshot.timelineDuration,
                sections: snapshot.sections,
                cuedSectionID: isCurrent ? cuedSectionID : nil,
                cueFlashPhase: isCurrent ? cueFlashPhase : false,
                showsPlayhead: isCurrent,
                isInteractive: isCurrent,
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

private struct LiveSectionWaveformCanvas: View {
    let bars: [Float]
    let sections: [ArrangementDisplaySection]
    let timelineDuration: TimeInterval
    let contentWidth: CGFloat

    private let minBarHeight: CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            drawWaveform(in: &context, size: size)
        }
        .drawingGroup()
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        guard !bars.isEmpty else { return }

        let midY = size.height / 2
        let barWidth = size.width / CGFloat(bars.count)
        let maxBarHeight = midY * 0.88
        let sortedSections = sections.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        let usesSections = !sortedSections.isEmpty

        for barIndex in 0..<bars.count {
            let barCenterX = CGFloat(barIndex) * barWidth + barWidth * 0.5
            let barHeight = max(minBarHeight, CGFloat(bars[barIndex]) * maxBarHeight)

            let fillColor: Color
            if usesSections {
                let arrangementTime = timelineDuration * (Double(barIndex) + 0.5) / Double(bars.count)
                let sectionIndex = sectionIndex(containing: arrangementTime, in: sortedSections)
                fillColor = ArrangementSectionPalette.colors(for: sectionIndex).accent.opacity(0.85)
            } else {
                fillColor = Color.dawWaveformFill
            }

            var path = Path()
            let leftX = barCenterX - barWidth * 0.45
            let rightX = barCenterX + barWidth * 0.45

            path.move(to: CGPoint(x: leftX, y: midY))
            path.addLine(to: CGPoint(x: barCenterX, y: midY - barHeight))
            path.addLine(to: CGPoint(x: rightX, y: midY))
            path.addLine(to: CGPoint(x: barCenterX, y: midY + barHeight))
            path.closeSubpath()

            context.fill(path, with: .color(fillColor))
        }
    }

    private func sectionIndex(
        containing time: TimeInterval,
        in sections: [ArrangementDisplaySection]
    ) -> Int {
        for (index, section) in sections.enumerated() {
            if time >= section.timelineStartSeconds, time < section.timelineEndSeconds {
                return index
            }
        }
        return 0
    }
}
