import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct EditView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song
    let viewModel: SongEditorViewModel
    let arrangementMarkers: [ArrangementMarker]
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]

    @State private var timelineZoom: CGFloat = 1
    @State private var timelineViewportWidth: CGFloat = 0
    @State private var hasSetInitialTimelineZoom = false
    @State private var pinchStartZoom: CGFloat?
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var showingArrangementEditor = false
    @State private var selectedClip: SelectedArrangementClip?
    @FocusState private var isTimelineFocused: Bool
    @State private var cachedRulerSections: [ArrangementDisplaySection] = []
    @State private var cachedTrackSections: [UUID: [ArrangementDisplaySection]] = [:]

    private var markers: [ArrangementMarker] {
        arrangementMarkers.sortedByTime
    }

    private var sourceDuration: TimeInterval {
        song.sortedTracks
            .map { viewModel.fileDuration(for: $0) }
            .max() ?? AudioEngineManager.shared.duration
    }

    private var sourceDurationForTrack: (UUID) -> TimeInterval {
        { trackID in
            guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return 1 }
            return viewModel.fileDuration(for: track)
        }
    }

    private var rulerSections: [ArrangementDisplaySection] {
        cachedRulerSections
    }

    private func trackSections(for track: AudioTrack) -> [ArrangementDisplaySection] {
        cachedTrackSections[track.id] ?? []
    }

    private func layoutInputs() -> ArrangementLayoutInputs {
        SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: song.sortedTracks.map(\.id),
            sourceDurationForTrack: sourceDurationForTrack
        )
    }

    private func refreshTimelineLayout() {
        let layout = viewModel.buildArrangementLayout(
            markers: markers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips
        )
        cachedRulerSections = layout.rulerSections
        cachedTrackSections = layout.trackSections
    }

    private func refreshTrackTimelineLayout(for trackID: UUID) {
        let inputs = layoutInputs()
        cachedTrackSections[trackID] = SongArrangementStore.trackDisplaySections(
            for: trackID,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            inputs: inputs
        )
    }

    private func persistArrangement() {
        SongArrangementStore.saveAsync(
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            for: song.id
        )
    }

    private func syncPlayback() {
        viewModel.syncArrangement(
            markers: markers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips
        )
    }

    private func syncTrackPlayback(for trackID: UUID) {
        viewModel.syncTrackArrangement(
            trackID: trackID,
            markers: markers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips
        )
    }

    private func commitTrackArrangementChange(for trackID: UUID) {
        refreshTrackTimelineLayout(for: trackID)
        syncTrackPlayback(for: trackID)
    }

    private var displaySections: [ArrangementDisplaySection] {
        rulerSections
    }

    private var timelineDuration: TimeInterval {
        if !displaySections.isEmpty {
            return max(displaySections.last?.timelineEndSeconds ?? 1, 1)
        }
        return max(sourceDuration, AudioEngineManager.shared.duration, 1)
    }

    private var timelineMinZoom: CGFloat {
        TimelineLayout.minZoom(duration: timelineDuration, viewportWidth: timelineViewportWidth)
    }

    private var timelineContentWidth: CGFloat {
        TimelineLayout.contentWidth(for: timelineDuration, zoom: timelineZoom)
    }

    private var hasTimelineContent: Bool {
        !song.sortedTracks.isEmpty || !displaySections.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar

            if hasTimelineContent {
                dawTimeline
            } else {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "waveform",
                    description: Text("Import stems before editing, or add an Ableton file for section markers.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.dawTimelineBackground)
        .focusable()
        .focused($isTimelineFocused)
        .focusEffectDisabled()
        .onAppear {
            refreshTimelineLayout()
            isTimelineFocused = true
        }
        .onChange(of: selectedClip) { _, newValue in
            if newValue != nil {
                isTimelineFocused = true
            }
        }
        .onChange(of: arrangementSlots) { _, _ in
            refreshTimelineLayout()
            syncPlayback()
        }
        .onChange(of: arrangementMarkers) { _, _ in
            refreshTimelineLayout()
        }
        .onChange(of: timelineDuration) { _, _ in
            clampTimelineZoom()
        }
        .onChange(of: timelineViewportWidth) { _, _ in
            clampTimelineZoom()
        }
        .background {
            SectionCueMonitor(
                cuedSectionID: cuedSectionID,
                cueFireTime: cueFireTime,
                onFire: fireMarkerCue
            )
        }
        .task(id: cuedSectionID) {
            guard cuedSectionID != nil else {
                cueFlashPhase = false
                return
            }
            cueFlashPhase = true
            while !Task.isCancelled, cuedSectionID != nil {
                try? await Task.sleep(for: .milliseconds(350))
                cueFlashPhase.toggle()
            }
        }
        .onDeleteCommand {
            removeSelectedClip()
        }
    }

    private func removeSelectedClip() {
        guard let selectedClip else { return }
        let trackID = selectedClip.trackID
        SongArrangementStore.removeClip(
            slotID: selectedClip.slotID,
            trackID: trackID,
            clipTrims: &clipTrims,
            removedClips: &removedClips
        )
        self.selectedClip = nil
        clearMarkerCue(cancellingScheduledTransition: false)
        persistArrangement()
        commitTrackArrangementChange(for: trackID)
    }

    private func clearMarkerCue(cancellingScheduledTransition: Bool = true) {
        if cancellingScheduledTransition, cuedSectionID != nil {
            viewModel.cancelScheduledSectionTransition()
        }
        cuedSectionID = nil
        cueFireTime = nil
        cueFlashPhase = false
    }

    private func cueSection(_ section: ArrangementDisplaySection) {
        cuedSectionID = section.id
        let audioEngine = AudioEngineManager.shared

        if let currentSection = displaySections.first(where: {
            audioEngine.currentTime >= $0.timelineStartSeconds
                && audioEngine.currentTime < $0.timelineEndSeconds
        }) {
            cueFireTime = currentSection.timelineEndSeconds
        } else {
            cueFireTime = section.timelineEndSeconds
        }

        guard viewModel.isLoaded else { return }
        viewModel.scheduleSectionTransition(
            to: section.timelineStartSeconds,
            at: cueFireTime ?? section.timelineStartSeconds
        )
        if !audioEngine.isPlaying {
            viewModel.play()
        }
    }

    private func fireMarkerCue() {
        guard let cueFireTime, let cuedSectionID else { return }
        let time = AudioEngineManager.shared.currentTime
        guard time >= cueFireTime else { return }
        guard let section = displaySections.first(where: { $0.id == cuedSectionID }) else {
            clearMarkerCue(cancellingScheduledTransition: false)
            return
        }

        viewModel.snapToScheduledSection(section.timelineStartSeconds)
        clearMarkerCue(cancellingScheduledTransition: false)
    }

    private func seekOnTimeline(to time: TimeInterval) {
        viewModel.seekAndPlay(to: time)
    }

    private func formatClipDuration(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func clampTimelineZoom() {
        guard timelineViewportWidth > 0 else { return }
        let minZoom = timelineMinZoom
        if !hasSetInitialTimelineZoom {
            timelineZoom = minZoom
            hasSetInitialTimelineZoom = true
        } else {
            timelineZoom = min(TimelineLayout.maxZoom, max(minZoom, timelineZoom))
        }
    }

    private var transportBar: some View {
        EditTransportBar(
            viewModel: viewModel,
            markers: markers,
            displaySections: displaySections,
            selectedClip: selectedClip,
            song: song,
            trackSections: trackSections(for:),
            formatClipDuration: formatClipDuration,
            showingArrangementEditor: $showingArrangementEditor,
            arrangementSlots: $arrangementSlots,
            clipTrims: $clipTrims,
            removedClips: $removedClips,
            onClearMarkerCue: { clearMarkerCue() }
        )
    }

    private var dawTimeline: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            TimelineRulerView(
                                duration: timelineDuration,
                                contentWidth: timelineContentWidth,
                                sections: displaySections,
                                cuedSectionID: cuedSectionID,
                                cueFlashPhase: cueFlashPhase,
                                sectionMarkerHeight: TimelineLayout.sectionMarkerHeight,
                                rulerHeight: TimelineLayout.rulerHeight,
                                onSeek: { time in
                                    clearMarkerCue()
                                    seekOnTimeline(to: time)
                                },
                                onCueSection: cueSection
                            )
                            .frame(height: TimelineLayout.rulerTotalHeight)
                            .id("\(displaySections.map(\.id))|\(timelineContentWidth)")

                            VStack(spacing: TimelineLayout.laneSpacing) {
                                ForEach(song.sortedTracks) { track in
                                    WaveformLaneView(
                                        track: track,
                                        fileURL: FileStore.trackURL(
                                            songID: song.id,
                                            relativePath: track.relativeFilePath
                                        ),
                                        fileDuration: viewModel.fileDuration(for: track),
                                        timelineDuration: timelineDuration,
                                        timelineContentWidth: timelineContentWidth,
                                        arrangementSections: trackSections(for: track),
                                        arrangementSlots: $arrangementSlots,
                                        clipTrims: $clipTrims,
                                        selectedClip: $selectedClip,
                                        markers: markers,
                                        laneHeight: TimelineLayout.laneHeight,
                                        onTrimChange: {
                                            viewModel.updateTrim(for: track, context: modelContext)
                                        },
                                        onCueSection: cueSection,
                                        onClipTrimCommitted: {
                                            persistArrangement()
                                            commitTrackArrangementChange(for: track.id)
                                        }
                                    )
                                }
                            }
                        }
                        .frame(width: timelineContentWidth, alignment: .leading)
                        .background {
                            TimelineMeasureGridOverlay(
                                duration: timelineDuration,
                                bpm: song.bpm,
                                rulerHeight: TimelineLayout.rulerTotalHeight
                            )
                        }

                        TimelinePlayheadOverlay(
                            duration: timelineDuration,
                            contentWidth: timelineContentWidth,
                            height: timelinePlayheadHeight
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    timelineViewportWidth = width
                }
                .simultaneousGesture(timelinePinchGesture)
                .onTapGesture {
                    isTimelineFocused = true
                }

                trackHeaderColumn
            }
        }
    }

    private var trackAreaHeight: CGFloat {
        let count = song.sortedTracks.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * TimelineLayout.laneHeight
            + CGFloat(count - 1) * TimelineLayout.laneSpacing
    }

    private var timelinePlayheadHeight: CGFloat {
        TimelineLayout.rulerTotalHeight + trackAreaHeight
    }

    private var trackHeaderColumn: some View {
        VStack(spacing: 0) {
            trackHeaderRulerCorner

            VStack(spacing: TimelineLayout.laneSpacing) {
                ForEach(song.sortedTracks) { track in
                    TrackLaneHeaderView(
                        track: track,
                        fileDuration: viewModel.fileDuration(for: track),
                        laneHeight: TimelineLayout.laneHeight,
                        onMixChange: {
                            viewModel.updateMix(for: track, context: modelContext)
                        }
                    )
                }
            }
        }
        .frame(width: TimelineLayout.trackHeaderWidth)
        .background(Color.dawTrackHeaderColumnBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.dawTimelineDivider)
                .frame(width: 1)
        }
    }

    private var trackHeaderRulerCorner: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TimelineLayout.sectionMarkerHeight)

            ZStack {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))

                Text("Tracks")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: TimelineLayout.rulerHeight)
        }
        .frame(width: TimelineLayout.trackHeaderWidth, height: TimelineLayout.rulerTotalHeight)
        .background(Color.dawTrackHeaderBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.dawTimelineDivider)
                .frame(height: 1)
        }
    }

    private var timelinePinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStartZoom == nil {
                    pinchStartZoom = timelineZoom
                }
                guard let pinchStartZoom else { return }
                let next = pinchStartZoom * scale
                timelineZoom = min(TimelineLayout.maxZoom, max(timelineMinZoom, next))
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }
}

private struct EditTransportBar: View {
    let viewModel: SongEditorViewModel
    let markers: [ArrangementMarker]
    let displaySections: [ArrangementDisplaySection]
    let selectedClip: SelectedArrangementClip?
    @Bindable var song: Song
    let trackSections: (AudioTrack) -> [ArrangementDisplaySection]
    let formatClipDuration: (TimeInterval) -> String
    @Binding var showingArrangementEditor: Bool
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]
    let onClearMarkerCue: () -> Void

    @Bindable private var audioEngine = AudioEngineManager.shared

    var body: some View {
        VStack(spacing: 8) {
            TransportControls(
                audioEngine: audioEngine,
                isLoaded: viewModel.isLoaded,
                duration: audioEngine.duration,
                onPlay: viewModel.play,
                onPause: viewModel.pause,
                onStop: {
                    onClearMarkerCue()
                    viewModel.stop()
                }
            )

            if !markers.isEmpty {
                arrangementEditorButton
            }

            if let loadError = viewModel.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let selectedClip,
               let track = song.sortedTracks.first(where: { $0.id == selectedClip.trackID }),
               let section = trackSections(track).first(where: { $0.id == selectedClip.slotID }) {
                HStack(spacing: 12) {
                    Text("Selected: \(section.name) — \(track.displayName)")
                        .font(.caption.weight(.medium))
                    Text(formatClipDuration(section.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    #if os(macOS)
                    Text("Press Delete to remove")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
            } else if !displaySections.isEmpty {
                Text("Click a track clip to select it. Drag clip edges to trim. Double-click a section marker to cue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var arrangementEditorButton: some View {
        Button {
            showingArrangementEditor = true
        } label: {
            Label("Arrangement", systemImage: "list.bullet.rectangle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingArrangementEditor, arrowEdge: .bottom) {
            ArrangementEditorMenu(
                slots: $arrangementSlots,
                clipTrims: $clipTrims,
                removedClips: $removedClips,
                markers: markers,
                songID: song.id
            )
        }
    }

}

private struct TimelineMeasureGridOverlay: View {
    let duration: TimeInterval
    let bpm: Double?
    let rulerHeight: CGFloat

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private func measureBoundaries(for contentWidth: CGFloat) -> [TimeInterval] {
        guard let bpm, bpm > 0, contentWidth > 0 else { return [] }
        return MeasureTiming.visibleMeasureBoundaries(
            duration: safeDuration,
            bpm: bpm,
            contentWidth: contentWidth
        )
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let boundaries = measureBoundaries(for: size.width)
            let rulerLineColor = Color.dawMeasureGridLine
            let trackLineColor = Color.dawMeasureGridLine.opacity(0.75)
            let rulerLineEnd = min(rulerHeight, size.height)

            for time in boundaries {
                let x = TimelineLayout.xPosition(
                    for: time,
                    duration: safeDuration,
                    contentWidth: size.width
                )
                guard x >= 0, x <= size.width else { continue }

                var rulerPath = Path()
                rulerPath.move(to: CGPoint(x: x, y: 0))
                rulerPath.addLine(to: CGPoint(x: x, y: rulerLineEnd))
                context.stroke(rulerPath, with: .color(rulerLineColor), lineWidth: 1)

                guard size.height > rulerLineEnd else { continue }

                var trackPath = Path()
                trackPath.move(to: CGPoint(x: x, y: rulerLineEnd))
                trackPath.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(trackPath, with: .color(trackLineColor), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TimelineRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let sections: [ArrangementDisplaySection]
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    let sectionMarkerHeight: CGFloat
    let rulerHeight: CGFloat
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionMarkerRow
                .frame(width: contentWidth, height: sectionMarkerHeight)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))

                ForEach(tickTimes, id: \.self) { time in
                    let x = TimelineLayout.xPosition(
                        for: time,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )

                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 8)
                        Text(formatRulerTime(time))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .offset(x: x)
                }
            }
            .frame(width: contentWidth, height: rulerHeight)
            .contentShape(Rectangle())
            .gesture(seekGesture)
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.dawTimelineDivider)
                .frame(height: 1)
        }
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                let time = TimelineLayout.time(
                    at: value.location.x,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                onSeek(time)
            }
    }

    private var tickTimes: [TimeInterval] {
        let tickInterval = tickIntervalSeconds
        let tickCount = max(2, Int(duration / tickInterval) + 1)
        return (0..<tickCount).map { Double($0) * tickInterval }
    }

    private var tickIntervalSeconds: TimeInterval {
        let pixelsPerTick: CGFloat = 80
        let pixelsPerSecond = contentWidth / safeDuration
        let rawInterval = Double(pixelsPerTick / pixelsPerSecond)
        let candidates: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first(where: { $0 >= rawInterval }) ?? 300
    }

    @ViewBuilder
    private var sectionMarkerRow: some View {
        if sections.isEmpty {
            Color.clear
        } else {
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(width: contentWidth, height: sectionMarkerHeight)

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let startX = TimelineLayout.xPosition(
                        for: section.timelineStartSeconds,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )
                    let endX = TimelineLayout.xPosition(
                        for: section.timelineEndSeconds,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )
                    let segmentWidth = max(0, endX - startX)
                    let isCued = cuedSectionID == section.id

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(sectionColor(index).opacity(isCued && cueFlashPhase ? 0.55 : 0.25))

                        Text(section.name)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(sectionColor(index))
                            .padding(.horizontal, 4)
                            .frame(width: segmentWidth, alignment: .leading)
                    }
                    .frame(width: segmentWidth, height: sectionMarkerHeight)
                    .overlay {
                        if isCued {
                            Rectangle()
                                .stroke(Color.yellow.opacity(cueFlashPhase ? 1 : 0.35), lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onCueSection(section)
                    }
                    .contextMenu {
                        Button("Cue Section") {
                            onCueSection(section)
                        }
                    }
                    .offset(x: startX)
                    #if os(macOS)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    #endif
                }

                ForEach(sections) { section in
                    let x = TimelineLayout.xPosition(
                        for: section.timelineStartSeconds,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 1, height: sectionMarkerHeight)
                        .offset(x: x)
                }
            }
        }
    }

    private func sectionColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .mint, .cyan]
        return colors[index % colors.count]
    }

    private func formatRulerTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    EditView(
        song: Song(name: "Preview"),
        viewModel: SongEditorViewModel(song: Song(name: "Preview")),
        arrangementMarkers: [],
        arrangementSlots: .constant([]),
        clipTrims: .constant([]),
        removedClips: .constant([])
    )
}
