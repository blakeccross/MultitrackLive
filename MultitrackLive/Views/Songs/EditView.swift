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
    @Binding var loopSlotIDs: Set<UUID>
    @Binding var tempoChanges: [TempoChange]
    @Binding var timeSignatureChanges: [TimeSignatureChange]

    @State private var timelineZoom: CGFloat = 1
    @State private var timelineViewportWidth: CGFloat = 0
    @State private var hasSetInitialTimelineZoom = false
    @State private var pinchStartZoom: CGFloat?
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var showingArrangementEditor = false
    @State private var showingTimeSignatureEditor = false
    @State private var showingGroupEditor = false
    @State private var showingChangeKey = false
    @State private var showingTempoEditor = false
    @State private var editingTempoMarkerID: UUID?
    @State private var showingTimeSignatureMarkerEditor = false
    @State private var editingTimeSignatureMarkerID: UUID?
    @State private var selectedClip: SelectedArrangementClip?
    @FocusState private var isTimelineFocused: Bool
    @State private var cachedRulerSections: [ArrangementDisplaySection] = []
    @State private var cachedTrackSections: [UUID: [ArrangementDisplaySection]] = [:]
    @State private var timelineVerticalScrollOffset: CGFloat = 0

    private let timelineVerticalScrollSpace = "editTimelineVerticalScroll"

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var trackGroups: [TrackGroup]

    private var measureNumerator: Int {
        normalizedTimeSignatureChanges.referenceNumerator
    }

    private var measureDenominator: Int {
        normalizedTimeSignatureChanges.referenceDenominator
    }

    private var normalizedTimeSignatureChanges: [TimeSignatureChange] {
        timeSignatureChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
            defaultDenominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
        )
    }

    private var normalizedTempoChanges: [TempoChange] {
        tempoChanges.normalizedEnsuringInitialMarker(defaultBPM: song.bpm ?? TempoChange.defaultBPM)
    }

    private func persistTempoChanges() {
        let normalized = normalizedTempoChanges
        tempoChanges = normalized
        if song.bpm != normalized.referenceBPM {
            song.bpm = normalized.referenceBPM
            try? modelContext.save()
        }
        try? TempoStore.save(normalized, for: song.id)
        viewModel.syncTempoMap(normalized, timeSignatureChanges: normalizedTimeSignatureChanges)
    }

    private func persistTimeSignatureChanges() {
        let normalized = normalizedTimeSignatureChanges
        timeSignatureChanges = normalized
        if song.timeSignatureNumerator != normalized.referenceNumerator {
            song.timeSignatureNumerator = normalized.referenceNumerator
            try? modelContext.save()
        }
        if song.timeSignatureDenominator != normalized.referenceDenominator {
            song.timeSignatureDenominator = normalized.referenceDenominator
            try? modelContext.save()
        }
        try? TimeSignatureStore.save(normalized, for: song.id)
        viewModel.syncTempoMap(normalizedTempoChanges, timeSignatureChanges: normalized)
    }

    private func handleTempoRulerTap(at time: TimeInterval) {
        let boundary = MeasureTiming.nearestMeasureBoundary(
            to: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )

        if let existing = normalizedTempoChanges.first(where: { $0.startMeasure == boundary.measure }) {
            editingTempoMarkerID = existing.id
        } else {
            let activeBPM = MeasureTiming.activeBPM(
                at: boundary.time,
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges
            )
            let newMarker = TempoChange(startMeasure: boundary.measure, bpm: activeBPM)
            tempoChanges = (normalizedTempoChanges + [newMarker]).normalizedEnsuringInitialMarker(
                defaultBPM: song.bpm ?? TempoChange.defaultBPM
            )
            editingTempoMarkerID = tempoChanges.first(where: { $0.startMeasure == boundary.measure })?.id
        }
        showingTempoEditor = true
    }

    private func deleteTempoMarker(_ marker: TempoChange) {
        guard marker.startMeasure > 1 else { return }
        tempoChanges.removeAll { $0.id == marker.id }
        tempoChanges = normalizedTempoChanges
        persistTempoChanges()
    }

    private func handleTimeSignatureRulerTap(at time: TimeInterval) {
        let boundary = MeasureTiming.nearestMeasureBoundary(
            to: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )

        if let existing = normalizedTimeSignatureChanges.first(where: { $0.startMeasure == boundary.measure }) {
            editingTimeSignatureMarkerID = existing.id
        } else {
            let activeSignature = normalizedTimeSignatureChanges.active(atMeasure: boundary.measure)
                ?? normalizedTimeSignatureChanges.first!
            let newMarker = TimeSignatureChange(
                numerator: activeSignature.numerator,
                denominator: activeSignature.denominator,
                startMeasure: boundary.measure
            )
            timeSignatureChanges = (normalizedTimeSignatureChanges + [newMarker]).normalizedEnsuringInitialMarker(
                defaultNumerator: measureNumerator,
                defaultDenominator: measureDenominator
            )
            editingTimeSignatureMarkerID = timeSignatureChanges.first(where: { $0.startMeasure == boundary.measure })?.id
        }
        showingTimeSignatureMarkerEditor = true
    }

    private func deleteTimeSignatureMarker(_ marker: TimeSignatureChange) {
        guard marker.startMeasure > 1 else { return }
        timeSignatureChanges.removeAll { $0.id == marker.id }
        timeSignatureChanges = normalizedTimeSignatureChanges
        persistTimeSignatureChanges()
    }

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
            loopSlotIDs: loopSlotIDs,
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
#if os(macOS)
            EditTransportStatusStrip(viewModel: viewModel)
#else
            transportBar
#endif

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
            tempoChanges = normalizedTempoChanges
            timeSignatureChanges = normalizedTimeSignatureChanges
            viewModel.syncTempoMap(tempoChanges, timeSignatureChanges: timeSignatureChanges)
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
        .sheet(isPresented: $showingGroupEditor) {
            TrackGroupEditorView()
        }
        .sheet(isPresented: $showingChangeKey) {
            ChangeKeyDialog(song: song, viewModel: viewModel)
        }
#if os(macOS)
        .toolbar {
            EditSongToolbarContent(
                viewModel: viewModel,
                markers: markers,
                song: song,
                showingArrangementEditor: $showingArrangementEditor,
                showingTimeSignatureEditor: $showingTimeSignatureEditor,
                timeSignatureChanges: $timeSignatureChanges,
                normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
                onPersistTimeSignatureChanges: persistTimeSignatureChanges,
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersistTempoChanges: persistTempoChanges,
                showingChangeKey: $showingChangeKey,
                arrangementSlots: $arrangementSlots,
                clipTrims: $clipTrims,
                removedClips: $removedClips,
                loopSlotIDs: $loopSlotIDs,
                onClearMarkerCue: { clearMarkerCue() }
            )
        }
        .toolbarBackground(.bar, for: .windowToolbar)
        .modifier(EditViewMacToolbarBackgroundVisibilityModifier())
#endif
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

    private func toggleLoopSection(_ section: ArrangementDisplaySection) {
        if loopSlotIDs.contains(section.id) {
            loopSlotIDs.remove(section.id)
        } else {
            loopSlotIDs.insert(section.id)
        }
        persistArrangement()
    }

    private func seekOnTimeline(to time: TimeInterval) {
        viewModel.seekAndPlay(to: time)
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
            song: song,
            showingArrangementEditor: $showingArrangementEditor,
            showingTimeSignatureEditor: $showingTimeSignatureEditor,
            timeSignatureChanges: $timeSignatureChanges,
            normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
            onPersistTimeSignatureChanges: persistTimeSignatureChanges,
            tempoChanges: $tempoChanges,
            normalizedTempoChanges: normalizedTempoChanges,
            onPersistTempoChanges: persistTempoChanges,
            showingChangeKey: $showingChangeKey,
            arrangementSlots: $arrangementSlots,
            clipTrims: $clipTrims,
            removedClips: $removedClips,
            loopSlotIDs: $loopSlotIDs,
            onClearMarkerCue: { clearMarkerCue() }
        )
    }

    private var dawTimeline: some View {
        GeometryReader { geometry in
            let tracksViewportHeight = max(0, geometry.size.height - TimelineLayout.rulerTotalHeight)

            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        timelineRulerStack
                            .frame(width: timelineContentWidth, height: TimelineLayout.rulerTotalHeight)

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 0) {
                                TimelineVerticalScrollOffsetReporter(
                                    coordinateSpaceName: timelineVerticalScrollSpace
                                )
                                trackTimelineScrollContent
                                    .frame(width: timelineContentWidth, alignment: .leading)
                            }
                        }
                        .coordinateSpace(name: timelineVerticalScrollSpace)
                        .modifier(TimelineVerticalScrollOffsetObserver(offset: $timelineVerticalScrollOffset))
                        .frame(height: tracksViewportHeight)
                    }
                    .frame(width: timelineContentWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    timelineViewportWidth = width
                }
                .simultaneousGesture(timelinePinchGesture)
                .onTapGesture {
                    isTimelineFocused = true
                }

                trackHeaderColumn(tracksViewportHeight: tracksViewportHeight)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var timelineRulerStack: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.dawStickyRulerBackground)
                .frame(width: timelineContentWidth, height: TimelineLayout.rulerTotalHeight)

            timelineRulerSection

            TimelineMeasureGridOverlay(
                duration: timelineDuration,
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges,
                rulerHeight: TimelineLayout.rulerTotalHeight
            )
            .allowsHitTesting(false)

            TimelinePlayheadOverlay(
                duration: timelineDuration,
                contentWidth: timelineContentWidth,
                height: TimelineLayout.rulerTotalHeight
            )
        }
        .frame(width: timelineContentWidth, height: TimelineLayout.rulerTotalHeight, alignment: .leading)
        .clipped()
    }

    private func trackHeaderColumn(tracksViewportHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            trackHeaderRulerCorner

            trackHeaderList
                .offset(y: -timelineVerticalScrollOffset)
                .frame(height: tracksViewportHeight, alignment: .top)
                .clipped()
        }
        .frame(width: TimelineLayout.trackHeaderWidth)
    }

    private var timelineRulerSection: some View {
        TimelineRulerView(
            duration: timelineDuration,
            contentWidth: timelineContentWidth,
            sections: displaySections,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges,
            cuedSectionID: cuedSectionID,
            cueFlashPhase: cueFlashPhase,
            loopSlotIDs: loopSlotIDs,
            sectionMarkerHeight: TimelineLayout.sectionMarkerHeight,
            timeSignatureRulerHeight: TimelineLayout.timeSignatureRulerHeight,
            tempoRulerHeight: TimelineLayout.tempoRulerHeight,
            rulerHeight: TimelineLayout.rulerHeight,
            onSeek: { time in
                clearMarkerCue()
                seekOnTimeline(to: time)
            },
            onCueSection: cueSection,
            onToggleLoopSection: toggleLoopSection,
            onTimeSignatureRulerTap: handleTimeSignatureRulerTap,
            onEditTimeSignatureMarker: { marker in
                editingTimeSignatureMarkerID = marker.id
                showingTimeSignatureMarkerEditor = true
            },
            onDeleteTimeSignatureMarker: deleteTimeSignatureMarker,
            onTempoRulerTap: handleTempoRulerTap,
            onEditTempoMarker: { marker in
                editingTempoMarkerID = marker.id
                showingTempoEditor = true
            },
            onDeleteTempoMarker: deleteTempoMarker
        )
        .frame(height: TimelineLayout.rulerTotalHeight)
        .id("\(displaySections.map(\.id))|\(timelineContentWidth)|\(normalizedTempoChanges.map(\.id))|\(normalizedTimeSignatureChanges.map(\.id))")
        .popover(isPresented: $showingTimeSignatureMarkerEditor, arrowEdge: .bottom) {
            if let markerID = editingTimeSignatureMarkerID,
               let marker = timeSignatureChanges.first(where: { $0.id == markerID }) {
                TimeSignatureMarkerEditorMenu(
                    marker: marker,
                    canDelete: marker.startMeasure > 1,
                    onApply: { numerator, denominator in
                        applyTimeSignatureMarker(
                            markerID: markerID,
                            numerator: numerator,
                            denominator: denominator
                        )
                    },
                    onDelete: {
                        if let marker = timeSignatureChanges.first(where: { $0.id == markerID }) {
                            deleteTimeSignatureMarker(marker)
                        }
                        showingTimeSignatureMarkerEditor = false
                        editingTimeSignatureMarkerID = nil
                    }
                )
            }
        }
        .popover(isPresented: $showingTempoEditor, arrowEdge: .bottom) {
            if let markerID = editingTempoMarkerID,
               let marker = tempoChanges.first(where: { $0.id == markerID }) {
                TempoMarkerEditorMenu(
                    marker: marker,
                    canDelete: marker.startMeasure > 1,
                    onApply: { bpm in
                        applyTempoMarker(markerID: markerID, bpm: bpm)
                    },
                    onDelete: {
                        if let marker = tempoChanges.first(where: { $0.id == markerID }) {
                            deleteTempoMarker(marker)
                        }
                        showingTempoEditor = false
                        editingTempoMarkerID = nil
                    }
                )
            }
        }
    }

    private var trackTimelineScrollContent: some View {
        ZStack(alignment: .topLeading) {
            trackLanesContent
                .background {
                    TimelineMeasureGridOverlay(
                        duration: timelineDuration,
                        tempoChanges: normalizedTempoChanges,
                        timeSignatureChanges: normalizedTimeSignatureChanges,
                        rulerHeight: 0
                    )
                }

            TimelinePlayheadOverlay(
                duration: timelineDuration,
                contentWidth: timelineContentWidth,
                height: trackAreaHeight
            )
        }
    }

    private var trackLanesContent: some View {
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
                    loopSlotIDs: loopSlotIDs,
                    onToggleLoopSection: toggleLoopSection,
                    onClipTrimCommitted: {
                        persistArrangement()
                        commitTrackArrangementChange(for: track.id)
                    }
                )
            }
        }
    }

    private var trackHeaderList: some View {
        VStack(spacing: TimelineLayout.laneSpacing) {
            ForEach(song.sortedTracks) { track in
                TrackLaneHeaderView(
                    track: track,
                    fileDuration: viewModel.fileDuration(for: track),
                    laneHeight: TimelineLayout.laneHeight,
                    groups: trackGroups,
                    onMixChange: {
                        viewModel.updateMix(for: track, context: modelContext)
                    },
                    onGroupChange: {
                        viewModel.updateGroup(for: track, context: modelContext)
                    },
                    onManageGroups: {
                        showingGroupEditor = true
                    }
                )
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

    private var trackAreaHeight: CGFloat {
        let count = song.sortedTracks.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * TimelineLayout.laneHeight
            + CGFloat(count - 1) * TimelineLayout.laneSpacing
    }

    private func applyTempoMarker(markerID: UUID, bpm: Double) {
        guard TempoChange.validBPMRange.contains(bpm) else { return }

        tempoChanges = tempoChanges.map { change in
            guard change.id == markerID else { return change }
            return TempoChange(
                id: change.id,
                startMeasure: change.startMeasure,
                bpm: bpm,
                sortOrder: change.sortOrder
            )
        }.normalizedEnsuringInitialMarker(defaultBPM: song.bpm ?? TempoChange.defaultBPM)

        persistTempoChanges()
        showingTempoEditor = false
        editingTempoMarkerID = nil
    }

    private func applyTimeSignatureMarker(markerID: UUID, numerator: Int, denominator: Int) {
        guard (1...32).contains(numerator),
              TimeSignatureChange.validDenominators.contains(denominator) else { return }

        timeSignatureChanges = timeSignatureChanges.map { change in
            guard change.id == markerID else { return change }
            return TimeSignatureChange(
                id: change.id,
                numerator: numerator,
                denominator: denominator,
                startMeasure: change.startMeasure,
                sortOrder: change.sortOrder
            )
        }.normalizedEnsuringInitialMarker(
            defaultNumerator: measureNumerator,
            defaultDenominator: measureDenominator
        )

        persistTimeSignatureChanges()
        showingTimeSignatureMarkerEditor = false
        editingTimeSignatureMarkerID = nil
    }

    private var trackHeaderRulerCorner: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TimelineLayout.sectionMarkerHeight)

            Color.clear
                .frame(height: TimelineLayout.timeSignatureRulerHeight)

            Color.clear
                .frame(height: TimelineLayout.tempoRulerHeight)

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

#if os(macOS)
private struct EditViewMacToolbarBackgroundVisibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}
#endif

private struct EditTransportStatusStrip: View {
    let viewModel: SongEditorViewModel

    var body: some View {
        if let loadError = viewModel.loadError {
            Text(loadError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }
}

#if os(macOS)
private struct EditSongToolbarContent: ToolbarContent {
    let viewModel: SongEditorViewModel
    let markers: [ArrangementMarker]
    @Bindable var song: Song
    @Binding var showingArrangementEditor: Bool
    @Binding var showingTimeSignatureEditor: Bool
    @Binding var timeSignatureChanges: [TimeSignatureChange]
    let normalizedTimeSignatureChanges: [TimeSignatureChange]
    let onPersistTimeSignatureChanges: () -> Void
    @Binding var tempoChanges: [TempoChange]
    let normalizedTempoChanges: [TempoChange]
    let onPersistTempoChanges: () -> Void
    @Binding var showingChangeKey: Bool
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]
    @Binding var loopSlotIDs: Set<UUID>
    let onClearMarkerCue: () -> Void

    @State private var showingTempoToolbarEditor = false
    @Bindable private var audioEngine = AudioEngineManager.shared

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                tempoEditorButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .navigation) {
                timeSignatureEditorButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                Spacer(minLength: 0)
            }

            ToolbarItem {
                transportStopButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                transportPlayButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem {
                Spacer(minLength: 0)
            }

            ToolbarItem(placement: .primaryAction) {
                changeKeyButton
            }
            .sharedBackgroundVisibility(.hidden)

            if !markers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    arrangementEditorButton
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            ToolbarItem(placement: .navigation) {
                tempoEditorButton
            }

            ToolbarItem(placement: .navigation) {
                timeSignatureEditorButton
            }

            ToolbarItem {
                Spacer(minLength: 0)
            }

            ToolbarItem {
                transportStopButton
            }

            ToolbarItem {
                transportPlayButton
            }

            ToolbarItem {
                Spacer(minLength: 0)
            }

            ToolbarItem(placement: .primaryAction) {
                changeKeyButton
            }

            if !markers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    arrangementEditorButton
                }
            }
        }
    }

    private var transportStopButton: some View {
        Button {
            onClearMarkerCue()
            viewModel.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isLoaded)
    }

    private var transportPlayButton: some View {
        Button(action: audioEngine.isPlaying ? viewModel.pause : viewModel.play) {
            Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isLoaded)
    }

    private var tempoEditorButton: some View {
        Button {
            showingTempoToolbarEditor = true
        } label: {
            Label(
                String(format: "%.0f BPM", normalizedTempoChanges.referenceBPM),
                systemImage: "metronome"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingTempoToolbarEditor, arrowEdge: .bottom) {
            TempoEditorMenu(
                song: song,
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersist: onPersistTempoChanges
            )
        }
    }

    private var changeKeyButton: some View {
        Button {
            showingChangeKey = true
        } label: {
            Label(changeKeyButtonTitle, systemImage: "key.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .disabled(song.sortedTracks.isEmpty)
    }

    private var changeKeyButtonTitle: String {
        switch song.transposeSemitones {
        case 0:
            return "Change Key"
        case 1:
            return "Key +1"
        case -1:
            return "Key -1"
        case let value where value > 0:
            return "Key +\(value)"
        default:
            return "Key \(song.transposeSemitones)"
        }
    }

    private var timeSignatureEditorButton: some View {
        Button {
            showingTimeSignatureEditor = true
        } label: {
            Label(
                song.timeSignatureDisplay ?? "4/4",
                systemImage: "music.quarternote.3"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingTimeSignatureEditor, arrowEdge: .bottom) {
            TimeSignatureEditorMenu(
                song: song,
                timeSignatureChanges: $timeSignatureChanges,
                normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
                onPersist: onPersistTimeSignatureChanges
            )
        }
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
                loopSlotIDs: $loopSlotIDs,
                markers: markers,
                songID: song.id
            )
        }
    }
}
#endif

private struct EditTransportBar: View {
    let viewModel: SongEditorViewModel
    let markers: [ArrangementMarker]
    @Bindable var song: Song
    @Binding var showingArrangementEditor: Bool
    @Binding var showingTimeSignatureEditor: Bool
    @Binding var timeSignatureChanges: [TimeSignatureChange]
    let normalizedTimeSignatureChanges: [TimeSignatureChange]
    let onPersistTimeSignatureChanges: () -> Void
    @Binding var tempoChanges: [TempoChange]
    let normalizedTempoChanges: [TempoChange]
    let onPersistTempoChanges: () -> Void
    @Binding var showingChangeKey: Bool
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]
    @Binding var loopSlotIDs: Set<UUID>
    let onClearMarkerCue: () -> Void

    @State private var showingTempoToolbarEditor = false
    @Bindable private var audioEngine = AudioEngineManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        tempoEditorButton
                        timeSignatureEditorButton
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        changeKeyButton
                        if !markers.isEmpty {
                            arrangementEditorButton
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        onClearMarkerCue()
                        viewModel.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2)
                    }
                    .disabled(!viewModel.isLoaded)

                    Button(action: audioEngine.isPlaying ? viewModel.pause : viewModel.play) {
                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    .disabled(!viewModel.isLoaded)
                }
            }
            .padding(.horizontal)

            if let loadError = viewModel.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var tempoEditorButton: some View {
        Button {
            showingTempoToolbarEditor = true
        } label: {
            Label(
                String(format: "%.0f BPM", normalizedTempoChanges.referenceBPM),
                systemImage: "metronome"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingTempoToolbarEditor, arrowEdge: .bottom) {
            TempoEditorMenu(
                song: song,
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersist: onPersistTempoChanges
            )
        }
    }

    private var changeKeyButton: some View {
        Button {
            showingChangeKey = true
        } label: {
            Label(changeKeyButtonTitle, systemImage: "key.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .disabled(song.sortedTracks.isEmpty)
    }

    private var changeKeyButtonTitle: String {
        switch song.transposeSemitones {
        case 0:
            return "Change Key"
        case 1:
            return "Key +1"
        case -1:
            return "Key -1"
        case let value where value > 0:
            return "Key +\(value)"
        default:
            return "Key \(song.transposeSemitones)"
        }
    }

    private var timeSignatureEditorButton: some View {
        Button {
            showingTimeSignatureEditor = true
        } label: {
            Label(
                song.timeSignatureDisplay ?? "4/4",
                systemImage: "music.quarternote.3"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingTimeSignatureEditor, arrowEdge: .bottom) {
            TimeSignatureEditorMenu(
                song: song,
                timeSignatureChanges: $timeSignatureChanges,
                normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
                onPersist: onPersistTimeSignatureChanges
            )
        }
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
                loopSlotIDs: $loopSlotIDs,
                markers: markers,
                songID: song.id
            )
        }
    }

}

private struct TimeSignatureEditorMenu: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song
    @Binding var timeSignatureChanges: [TimeSignatureChange]
    let normalizedTimeSignatureChanges: [TimeSignatureChange]
    let onPersist: () -> Void

    @State private var numerator: Int
    @State private var denominator: Int

    private static let presets: [(numerator: Int, denominator: Int)] = [
        (4, 4), (3, 4), (2, 4), (6, 8), (5, 4), (7, 8), (12, 8)
    ]

    private static let denominators = [2, 4, 8, 16]

    init(
        song: Song,
        timeSignatureChanges: Binding<[TimeSignatureChange]>,
        normalizedTimeSignatureChanges: [TimeSignatureChange],
        onPersist: @escaping () -> Void
    ) {
        self.song = song
        _timeSignatureChanges = timeSignatureChanges
        self.normalizedTimeSignatureChanges = normalizedTimeSignatureChanges
        self.onPersist = onPersist
        let initial = normalizedTimeSignatureChanges.first
        _numerator = State(initialValue: initial?.numerator ?? song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator)
        _denominator = State(initialValue: initial?.denominator ?? song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Time Signature")
                .font(.headline)

            Text("Edits the measure 1 time signature marker.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        applyTimeSignature(numerator: preset.numerator, denominator: preset.denominator)
                    } label: {
                        Text("\(preset.numerator)/\(preset.denominator)")
                            .font(.body.monospacedDigit().weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected(numerator: preset.numerator, denominator: preset.denominator) ? .accentColor : .secondary)
                }
            }

            Divider()

            HStack(spacing: 16) {
                Stepper(value: $numerator, in: 1...32) {
                    Text("Beats: \(numerator)")
                        .monospacedDigit()
                }
                .onChange(of: numerator) { _, newValue in
                    applyTimeSignature(numerator: newValue, denominator: denominator)
                }

                Picker("Beat value", selection: $denominator) {
                    ForEach(Self.denominators, id: \.self) { value in
                        Text("1/\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .onChange(of: denominator) { _, newValue in
                    applyTimeSignature(numerator: numerator, denominator: newValue)
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
        .onChange(of: song.timeSignatureNumerator) { _, _ in
            syncFromSong()
        }
        .onChange(of: song.timeSignatureDenominator) { _, _ in
            syncFromSong()
        }
    }

    private func isSelected(numerator: Int, denominator: Int) -> Bool {
        self.numerator == numerator && self.denominator == denominator
    }

    private func syncFromSong() {
        let initial = normalizedTimeSignatureChanges.first
        numerator = initial?.numerator ?? song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator
        denominator = initial?.denominator ?? song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
    }

    private func applyTimeSignature(numerator: Int, denominator: Int) {
        guard (1...32).contains(numerator), Self.denominators.contains(denominator) else { return }

        song.timeSignatureNumerator = numerator
        song.timeSignatureDenominator = denominator

        if let measureOneID = normalizedTimeSignatureChanges.first(where: { $0.startMeasure == 1 })?.id {
            timeSignatureChanges = timeSignatureChanges.map { change in
                guard change.id == measureOneID else { return change }
                return TimeSignatureChange(
                    id: change.id,
                    numerator: numerator,
                    denominator: denominator,
                    startMeasure: 1,
                    sortOrder: change.sortOrder
                )
            }
        } else {
            timeSignatureChanges = [
                TimeSignatureChange(
                    numerator: numerator,
                    denominator: denominator,
                    startMeasure: 1,
                    sortOrder: 0
                )
            ]
        }

        try? modelContext.save()
        onPersist()

        self.numerator = numerator
        self.denominator = denominator
    }
}

private struct TempoEditorMenu: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song
    @Binding var tempoChanges: [TempoChange]
    let normalizedTempoChanges: [TempoChange]
    let onPersist: () -> Void

    @State private var bpm: Double

    init(
        song: Song,
        tempoChanges: Binding<[TempoChange]>,
        normalizedTempoChanges: [TempoChange],
        onPersist: @escaping () -> Void
    ) {
        self.song = song
        _tempoChanges = tempoChanges
        self.normalizedTempoChanges = normalizedTempoChanges
        self.onPersist = onPersist
        _bpm = State(initialValue: normalizedTempoChanges.referenceBPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tempo")
                .font(.headline)

            Text("Edits the measure 1 tempo marker.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $bpm, in: TempoChange.validBPMRange, step: 0.1) {
                Text(String(format: "%.1f BPM", bpm))
                    .monospacedDigit()
            }
            .onChange(of: bpm) { _, newValue in
                applyTempo(newValue)
            }
        }
        .padding()
        .frame(minWidth: 280)
        .onChange(of: song.bpm) { _, _ in
            syncFromSong()
        }
    }

    private func syncFromSong() {
        bpm = normalizedTempoChanges.referenceBPM
    }

    private func applyTempo(_ bpm: Double) {
        guard TempoChange.validBPMRange.contains(bpm) else { return }

        song.bpm = bpm

        if let measureOneID = normalizedTempoChanges.first(where: { $0.startMeasure == 1 })?.id {
            tempoChanges = tempoChanges.map { change in
                guard change.id == measureOneID else { return change }
                return TempoChange(
                    id: change.id,
                    startMeasure: 1,
                    bpm: bpm,
                    sortOrder: change.sortOrder
                )
            }
        } else {
            tempoChanges = [
                TempoChange(startMeasure: 1, bpm: bpm, sortOrder: 0)
            ]
        }

        try? modelContext.save()
        onPersist()

        self.bpm = bpm
    }
}

private struct TempoMarkerEditorMenu: View {
    let marker: TempoChange
    let canDelete: Bool
    let onApply: (Double) -> Void
    let onDelete: () -> Void

    @State private var bpm: Double

    init(
        marker: TempoChange,
        canDelete: Bool,
        onApply: @escaping (Double) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.marker = marker
        self.canDelete = canDelete
        self.onApply = onApply
        self.onDelete = onDelete
        _bpm = State(initialValue: marker.bpm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tempo at Measure \(marker.startMeasure)")
                .font(.headline)

            Text("Affects measure grid spacing and playback speed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Stepper(value: $bpm, in: TempoChange.validBPMRange, step: 0.1) {
                    Text(String(format: "%.1f BPM", bpm))
                        .monospacedDigit()
                }

                Button("Apply") {
                    onApply(bpm)
                }
                .buttonStyle(.borderedProminent)
            }

            if canDelete {
                Divider()

                Button("Delete Marker", role: .destructive) {
                    onDelete()
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}

private struct TimelineVerticalScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TimelineVerticalScrollOffsetObserver: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newValue in
                    offset = newValue
                }
        } else {
            content
                .onPreferenceChange(TimelineVerticalScrollOffsetKey.self) { newValue in
                    offset = newValue
                }
        }
    }
}

private struct TimelineVerticalScrollOffsetReporter: View {
    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TimelineVerticalScrollOffsetKey.self,
                value: -proxy.frame(in: .named(coordinateSpaceName)).minY
            )
        }
        .frame(height: 0)
    }
}

private struct TimelineMeasureGridOverlay: View {
    let duration: TimeInterval
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let rulerHeight: CGFloat

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private func measureBoundaries(for contentWidth: CGFloat) -> [TimeInterval] {
        guard !tempoChanges.isEmpty, contentWidth > 0 else { return [] }
        return MeasureTiming.visibleMeasureBoundaries(
            duration: safeDuration,
            tempoChanges: tempoChanges,
            contentWidth: contentWidth,
            timeSignatureChanges: timeSignatureChanges
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
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    let loopSlotIDs: Set<UUID>
    let sectionMarkerHeight: CGFloat
    let timeSignatureRulerHeight: CGFloat
    let tempoRulerHeight: CGFloat
    let rulerHeight: CGFloat
    let onSeek: (TimeInterval) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onTimeSignatureRulerTap: (TimeInterval) -> Void
    let onEditTimeSignatureMarker: (TimeSignatureChange) -> Void
    let onDeleteTimeSignatureMarker: (TimeSignatureChange) -> Void
    let onTempoRulerTap: (TimeInterval) -> Void
    let onEditTempoMarker: (TempoChange) -> Void
    let onDeleteTempoMarker: (TempoChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionMarkerRow
                .frame(width: contentWidth, height: sectionMarkerHeight)

            TimelineTimeSignatureRulerView(
                duration: safeDuration,
                contentWidth: contentWidth,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges,
                height: timeSignatureRulerHeight,
                onTap: onTimeSignatureRulerTap,
                onEditMarker: onEditTimeSignatureMarker,
                onDeleteMarker: onDeleteTimeSignatureMarker
            )

            TimelineTempoRulerView(
                duration: safeDuration,
                contentWidth: contentWidth,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges,
                height: tempoRulerHeight,
                onTap: onTempoRulerTap,
                onEditMarker: onEditTempoMarker,
                onDeleteMarker: onDeleteTempoMarker
            )

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
                    let isLoopSection = loopSlotIDs.contains(section.id)

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(sectionColor(index).opacity(isCued && cueFlashPhase ? 0.55 : 0.25))

                        HStack(spacing: 2) {
                            if isLoopSection {
                                Image(systemName: "repeat")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(sectionColor(index))
                            }
                            Text(section.name)
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(sectionColor(index))
                        }
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
                        if isLoopSection {
                            Button("Remove Loop") {
                                onToggleLoopSection(section)
                            }
                        } else {
                            Button("Loop Section") {
                                onToggleLoopSection(section)
                            }
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

private struct TimelineTimeSignatureRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let height: CGFloat
    let onTap: (TimeInterval) -> Void
    let onEditMarker: (TimeSignatureChange) -> Void
    let onDeleteMarker: (TimeSignatureChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var sortedMarkers: [TimeSignatureChange] {
        timeSignatureChanges.sortedByMeasure
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))

            ForEach(Array(timeSignatureSegments.enumerated()), id: \.offset) { index, segment in
                let startX = TimelineLayout.xPosition(
                    for: segment.startTime,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                let endX = TimelineLayout.xPosition(
                    for: segment.endTime,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                let segmentWidth = max(0, endX - startX)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(timeSignatureColor(index).opacity(0.22))

                    Text(segment.displayName)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timeSignatureColor(index))
                        .padding(.horizontal, 4)
                        .frame(width: segmentWidth, alignment: .leading)
                        .lineLimit(1)
                }
                .frame(width: segmentWidth, height: height)
                .offset(x: startX)
            }

            ForEach(sortedMarkers) { marker in
                let time = MeasureTiming.timeAtStartOfMeasure(
                    marker.startMeasure,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )
                let x = TimelineLayout.xPosition(
                    for: time,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )

                Rectangle()
                    .fill(Color.indigo.opacity(0.85))
                    .frame(width: 2, height: height)
                    .offset(x: x)
                    .contextMenu {
                        Button("Edit Time Signature") {
                            onEditMarker(marker)
                        }
                        if marker.startMeasure > 1 {
                            Button("Delete Marker", role: .destructive) {
                                onDeleteMarker(marker)
                            }
                        }
                    }
            }
        }
        .frame(width: contentWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let time = TimelineLayout.time(
                        at: value.location.x,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )
                    onTap(time)
                }
        )
    }

    private struct TimeSignatureSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let displayName: String
    }

    private var timeSignatureSegments: [TimeSignatureSegment] {
        let markers = sortedMarkers
        guard !markers.isEmpty else { return [] }

        return markers.enumerated().map { index, marker in
            let startTime = MeasureTiming.timeAtStartOfMeasure(
                marker.startMeasure,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges
            )
            let endTime: TimeInterval
            if index + 1 < markers.count {
                endTime = MeasureTiming.timeAtStartOfMeasure(
                    markers[index + 1].startMeasure,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )
            } else {
                endTime = safeDuration
            }
            return TimeSignatureSegment(
                startTime: startTime,
                endTime: endTime,
                displayName: marker.displayName
            )
        }
    }

    private func timeSignatureColor(_ index: Int) -> Color {
        let colors: [Color] = [.indigo, .teal, .cyan, .blue, .mint]
        return colors[index % colors.count]
    }
}

private struct TimeSignatureMarkerEditorMenu: View {
    let marker: TimeSignatureChange
    let canDelete: Bool
    let onApply: (Int, Int) -> Void
    let onDelete: () -> Void

    @State private var numerator: Int
    @State private var denominator: Int

    private static let presets: [(numerator: Int, denominator: Int)] = [
        (4, 4), (3, 4), (2, 4), (6, 8), (5, 4), (7, 8), (12, 8)
    ]

    private static let denominators = [2, 4, 8, 16]

    init(
        marker: TimeSignatureChange,
        canDelete: Bool,
        onApply: @escaping (Int, Int) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.marker = marker
        self.canDelete = canDelete
        self.onApply = onApply
        self.onDelete = onDelete
        _numerator = State(initialValue: marker.numerator)
        _denominator = State(initialValue: marker.denominator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Measure \(marker.startMeasure)")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        numerator = preset.numerator
                        denominator = preset.denominator
                    } label: {
                        Text("\(preset.numerator)/\(preset.denominator)")
                            .font(.body.monospacedDigit().weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(
                        numerator == preset.numerator && denominator == preset.denominator
                            ? .accentColor
                            : .secondary
                    )
                }
            }

            Divider()

            HStack(spacing: 16) {
                Stepper(value: $numerator, in: 1...32) {
                    Text("Beats: \(numerator)")
                        .monospacedDigit()
                }

                Picker("Beat value", selection: $denominator) {
                    ForEach(Self.denominators, id: \.self) { value in
                        Text("1/\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            Button("Apply") {
                onApply(numerator, denominator)
            }
            .buttonStyle(.borderedProminent)

            if canDelete {
                Divider()

                Button("Delete Marker", role: .destructive) {
                    onDelete()
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}

private struct TimelineTempoRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let height: CGFloat
    let onTap: (TimeInterval) -> Void
    let onEditMarker: (TempoChange) -> Void
    let onDeleteMarker: (TempoChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var sortedMarkers: [TempoChange] {
        tempoChanges.sortedByMeasure
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))

            ForEach(Array(tempoSegments.enumerated()), id: \.offset) { index, segment in
                let startX = TimelineLayout.xPosition(
                    for: segment.startTime,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                let endX = TimelineLayout.xPosition(
                    for: segment.endTime,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                let segmentWidth = max(0, endX - startX)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(tempoColor(index).opacity(0.22))

                    Text(String(format: "%.0f", segment.bpm))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tempoColor(index))
                        .padding(.horizontal, 4)
                        .frame(width: segmentWidth, alignment: .leading)
                        .lineLimit(1)
                }
                .frame(width: segmentWidth, height: height)
                .offset(x: startX)
            }

            ForEach(sortedMarkers) { marker in
                let time = MeasureTiming.timeAtStartOfMeasure(
                    marker.startMeasure,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )
                let x = TimelineLayout.xPosition(
                    for: time,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )

                Rectangle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 2, height: height)
                    .offset(x: x)
                    .contextMenu {
                        Button("Edit Tempo") {
                            onEditMarker(marker)
                        }
                        if marker.startMeasure > 1 {
                            Button("Delete Marker", role: .destructive) {
                                onDeleteMarker(marker)
                            }
                        }
                    }
            }
        }
        .frame(width: contentWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let time = TimelineLayout.time(
                        at: value.location.x,
                        duration: safeDuration,
                        contentWidth: contentWidth
                    )
                    onTap(time)
                }
        )
    }

    private struct TempoSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let bpm: Double
    }

    private var tempoSegments: [TempoSegment] {
        let markers = sortedMarkers
        guard !markers.isEmpty else { return [] }

        return markers.enumerated().map { index, marker in
            let startTime = MeasureTiming.timeAtStartOfMeasure(
                marker.startMeasure,
                tempoChanges: tempoChanges,
                timeSignatureChanges: timeSignatureChanges
            )
            let endTime: TimeInterval
            if index + 1 < markers.count {
                endTime = MeasureTiming.timeAtStartOfMeasure(
                    markers[index + 1].startMeasure,
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: timeSignatureChanges
                )
            } else {
                endTime = safeDuration
            }
            return TempoSegment(startTime: startTime, endTime: endTime, bpm: marker.bpm)
        }
    }

    private func tempoColor(_ index: Int) -> Color {
        let colors: [Color] = [.orange, .pink, .yellow, .red, .brown]
        return colors[index % colors.count]
    }
}

#Preview {
    EditView(
        song: Song(name: "Preview"),
        viewModel: SongEditorViewModel(song: Song(name: "Preview")),
        arrangementMarkers: [],
        arrangementSlots: .constant([]),
        clipTrims: .constant([]),
        removedClips: .constant([]),
        loopSlotIDs: .constant([]),
        tempoChanges: .constant([TempoChange(startMeasure: 1, bpm: 120)]),
        timeSignatureChanges: .constant([
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0)
        ])
    )
}
