import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A timeline ruler selection spanning whole measures `[startMeasure, endMeasure)`.
private struct MeasureRangeSelection: Equatable {
    var startMeasure: Int
    var endMeasure: Int
}

typealias UndoableChangeHandler = (_ actionName: String, _ change: () -> Void) -> Void

struct EditView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song
    let viewModel: SongEditorViewModel
    let undoController: SongUndoController
    @Binding var arrangementMarkers: [ArrangementMarker]
    @Binding var arrangementSlots: [ArrangementSlot]
    @Binding var clipTrims: [ArrangementClipTrim]
    @Binding var removedClips: [ArrangementRemovedClip]
    @Binding var clipGaps: [ArrangementClipGap]
    @Binding var clipRegions: [ClipRegion]
    @Binding var loopSlotIDs: Set<UUID>
    @Binding var tempoChanges: [TempoChange]
    @Binding var timeSignatureChanges: [TimeSignatureChange]
    @Binding var midiEvents: [MIDIEvent]
    @Binding var showingSongLibrary: Bool

    @State private var showingMIDIDevicePicker = false
    @State private var showingMIDIDeviceEditor = false
    @State private var deviceBeingEdited: MIDIDevice?
    @State private var timelineZoom: CGFloat = 1
    @State private var timelineViewportWidth: CGFloat = 0
    @State private var hasSetInitialTimelineZoom = false
    @State private var pinchStartZoom: CGFloat?
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var sectionLoop = SectionLoopController()
    @State private var sectionAnnouncer = SectionAnnouncer()
    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var showingArrangementEditor = false
    @State private var showingTimeSignatureEditor = false
    @State private var showingGroupEditor = false
    @State private var showingChangeKey = false
    @State private var showingTempoEditor = false
    @State private var editingTempoMarkerID: UUID?
    @State private var showingTimeSignatureMarkerEditor = false
    @State private var editingTimeSignatureMarkerID: UUID?
    @State private var sectionPendingRename: ArrangementDisplaySection?
    @State private var trackPendingRename: AudioTrack?
    @State private var renameTrackName = ""
    @State private var clipSelection: TimelineClipSelection?
    @State private var rulerMeasureSelection: MeasureRangeSelection?
    @State private var selectedTrackID: UUID?
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
        persistProjectState()
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
        persistProjectState()
        viewModel.syncTempoMap(normalizedTempoChanges, timeSignatureChanges: normalized)
    }

    private func persistProjectState() {
        try? SongProjectBridge.persist(
            song: song,
            markers: markers,
            arrangementSlots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            loopSlotIDs: loopSlotIDs,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges,
            midiEvents: midiEvents,
            context: modelContext
        )
    }

    private func captureSnapshot() -> SongEditSnapshot {
        SongEditSnapshot.capture(
            song: song,
            markers: arrangementMarkers,
            arrangementSlots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            loopSlotIDs: loopSlotIDs,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            midiEvents: midiEvents
        )
    }

    private func applySnapshot(_ snapshot: SongEditSnapshot) {
        arrangementMarkers = snapshot.markers
        arrangementSlots = snapshot.arrangementSlots
        clipTrims = snapshot.clipTrims
        removedClips = snapshot.removedClips
        clipGaps = snapshot.clipGaps
        clipRegions = snapshot.clipRegions
        loopSlotIDs = snapshot.loopSlotIDs
        midiEvents = snapshot.midiEvents

        snapshot.applyMetadata(to: song)
        let trackIDsBeforeApply = Set(song.sortedTracks.map(\.id))
        snapshot.applyTracks(to: song, context: modelContext)
        let trackIDsChanged = trackIDsBeforeApply != Set(song.sortedTracks.map(\.id))

        let defaultBPM = song.bpm ?? TempoChange.defaultBPM
        let defaultNumerator = song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator
        let defaultDenominator = song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
        let normalizedTempo = snapshot.normalizedTempoChanges(defaultBPM: defaultBPM)
        let normalizedTimeSignature = snapshot.normalizedTimeSignatureChanges(
            defaultNumerator: defaultNumerator,
            defaultDenominator: defaultDenominator
        )
        tempoChanges = normalizedTempo
        timeSignatureChanges = normalizedTimeSignature

        try? SongProjectBridge.persist(
            song: song,
            markers: markers,
            arrangementSlots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            loopSlotIDs: loopSlotIDs,
            tempoChanges: normalizedTempo,
            timeSignatureChanges: normalizedTimeSignature,
            midiEvents: midiEvents,
            context: modelContext
        )
        try? modelContext.save()

        refreshTimelineLayout()
        syncPlayback()
        viewModel.syncTempoMap(normalizedTempo, timeSignatureChanges: normalizedTimeSignature)

        for track in song.sortedTracks {
            viewModel.updateMix(for: track, context: modelContext)
            viewModel.updateTrim(for: track, context: modelContext)
        }

        reconfigureMIDI()

        if snapshot.songMetadata.transposeHighQuality {
            Task {
                await viewModel.applyKeyChange(context: modelContext, highQuality: true)
            }
        } else if snapshot.songMetadata.transposeSemitones != 0 {
            Task {
                await viewModel.applyKeyChange(context: modelContext, highQuality: false)
            }
        }

        if trackIDsChanged {
            viewModel.loadSong()
        }
    }

    private func performUndoableChange(_ actionName: String, _ change: () -> Void) {
        guard !undoController.isApplyingUndo else {
            change()
            return
        }
        let before = captureSnapshot()
        change()
        let after = captureSnapshot()
        undoController.registerChange(
            actionName: actionName,
            before: before,
            after: after,
            apply: { snapshot in
                applySnapshot(snapshot)
            }
        )
    }

    private var undoableChange: UndoableChangeHandler {
        { actionName, change in
            performUndoableChange(actionName, change)
        }
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
        performUndoableChange("Delete Tempo Marker") {
            tempoChanges.removeAll { $0.id == marker.id }
            tempoChanges = normalizedTempoChanges
            persistTempoChanges()
        }
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
        performUndoableChange("Delete Time Signature Marker") {
            timeSignatureChanges.removeAll { $0.id == marker.id }
            timeSignatureChanges = normalizedTimeSignatureChanges
            persistTimeSignatureChanges()
        }
    }

    private var markers: [ArrangementMarker] {
        arrangementMarkers.sortedByTime
    }

    private var sourceDuration: TimeInterval {
        song.sortedTracks
            .map { viewModel.fileDuration(for: $0) }
            .max() ?? finiteEngineDuration
    }

    private var finiteEngineDuration: TimeInterval {
        AudioEngineManager.shared.duration
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
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
        cachedRulerSections = layout.rulerSections
        cachedTrackSections = layout.trackSections
    }

    private func persistArrangement() {
        persistProjectState()
    }

    private func syncPlayback() {
        viewModel.syncArrangement(
            markers: markers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
    }

    private func syncTrackPlayback(for trackID: UUID) {
        viewModel.syncTrackArrangement(
            trackID: trackID,
            markers: markers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            track: song.sortedTracks.first(where: { $0.id == trackID })
        )
    }

    private func commitTrackArrangementChange(for trackID: UUID) {
        refreshTimelineLayout()
        syncTrackPlayback(for: trackID)
    }

    private var displaySections: [ArrangementDisplaySection] {
        rulerSections
    }

    private func trackLaneSections(for track: AudioTrack) -> [ArrangementDisplaySection] {
        trackSections(for: track)
    }

    private func clipDisplaySections(for track: AudioTrack) -> [ArrangementDisplaySection] {
        let laneSections = trackLaneSections(for: track)
        if !laneSections.isEmpty {
            return laneSections
        }
        return SongArrangementStore.sourceTrackDisplaySections(
            trackID: track.id,
            trimStart: track.trimStartSeconds,
            trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
    }

    private var clipEditorActions: ClipEditorActions {
        ClipEditorActions(
            canSplit: clipSelection != nil,
            canJoin: clipSelection?.isWholeClip == true,
            split: { splitSelectedClipAtPlayhead() },
            join: { joinSelectedClipWithNext() }
        )
    }

    private var timelineDuration: TimeInterval {
        let hasTrackSections = cachedTrackSections.values.contains { !$0.isEmpty }
        if !displaySections.isEmpty || hasTrackSections {
            return SongArrangementStore.effectiveTimelineDuration(
                rulerSections: rulerSections,
                trackSections: cachedTrackSections
            )
        }
        return max(sourceDuration, finiteEngineDuration, 1)
    }

    private var timelineMinZoom: CGFloat {
        TimelineLayout.minZoom(duration: timelineDuration, viewportWidth: timelineViewportWidth)
    }

    private var timelineContentWidth: CGFloat {
        TimelineLayout.contentWidth(for: timelineDuration, zoom: timelineZoom)
    }

    /// Fills the scroll viewport when song content is narrower than the editor area.
    private var timelineDisplayWidth: CGFloat {
        max(timelineContentWidth, timelineViewportWidth)
    }

    private var hasTimelineContent: Bool {
        !song.sortedTracks.isEmpty || !displaySections.isEmpty || !song.midiTracks.isEmpty
    }

    private var midiTracks: [MIDITrack] {
        song.sortedMIDITracks
    }

    private func reconfigureMIDI() {
        let resolved = MIDIScheduler.scheduledEvents(events: midiEvents, tracks: midiTracks)
        AudioEngineManager.shared.configureMIDI(events: resolved)
    }

    private func commitMIDIEvents() {
        performUndoableChange("Edit MIDI") {
            persistProjectState()
            reconfigureMIDI()
        }
    }

    private func commitMIDIConfig() {
        try? modelContext.save()
        reconfigureMIDI()
    }

    private func createMIDITrack(for device: MIDIDevice) {
        let track = MIDITrack(
            displayName: device.name,
            sortOrder: midiTracks.count
        )
        track.device = device
        track.song = song
        modelContext.insert(track)
        song.midiTracks.append(track)
        try? modelContext.save()
        reconfigureMIDI()
    }

    private func editDevice(for track: MIDITrack) {
        guard let device = track.device else {
            showingMIDIDevicePicker = true
            return
        }
        deviceBeingEdited = device
        showingMIDIDeviceEditor = true
    }

    private func deleteMIDITrack(_ track: MIDITrack) {
        midiEvents.removeAll { $0.trackID == track.id }
        song.midiTracks.removeAll { $0.id == track.id }
        modelContext.delete(track)
        try? modelContext.save()
        commitMIDIEvents()
    }

    private func sendMIDITest(for track: MIDITrack) {
        guard let device = track.device,
              let uniqueID = device.destinationUniqueID,
              let command = device.commands.first else { return }
        MIDIOutputService.shared.sendNoteTestNow(
            note: command.note,
            channel: device.midiChannel,
            toUniqueID: uniqueID
        )
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
                AppEmptyState(
                    title: "No Tracks",
                    systemImage: "waveform",
                    description: "Import stems before editing, or add an Ableton file for section markers."
                )
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.dawTimelineBackground)
        .focusable()
        .focused($isTimelineFocused)
        .focusEffectDisabled()
        .focusedValue(\.clipEditorActions, clipEditorActions)
        .onAppear {
            refreshTimelineLayout()
            isTimelineFocused = true
            tempoChanges = normalizedTempoChanges
            timeSignatureChanges = normalizedTimeSignatureChanges
            viewModel.syncTempoMap(tempoChanges, timeSignatureChanges: timeSignatureChanges)
            reconfigureMIDI()
            prepareSectionAnnouncements()
        }
        .onChange(of: clipSelection) { _, newValue in
            if let trackID = newValue?.trackID {
                selectedTrackID = trackID
            }
            if newValue != nil {
                rulerMeasureSelection = nil
                isTimelineFocused = true
            }
        }
        .onChange(of: arrangementSlots) { _, _ in
            refreshTimelineLayout()
            syncPlayback()
            prepareSectionAnnouncements()
        }
        .onChange(of: arrangementMarkers) { _, _ in
            refreshTimelineLayout()
            prepareSectionAnnouncements()
        }
        .onChange(of: song.dynamicCuesEnabled) { _, _ in
            prepareSectionAnnouncements()
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
            SectionAnnounceMonitor(
                enabled: song.dynamicCuesEnabled,
                sections: displaySections,
                cuedSectionID: cuedSectionID,
                cueFireTime: cueFireTime,
                announcer: sectionAnnouncer
            )
            SectionLoopPlaybackSupport(
                loopController: sectionLoop,
                sections: displaySections,
                loopSlotIDs: loopSlotIDs,
                onLoop: { section in
                    viewModel.snapToScheduledSection(section.timelineStartSeconds)
                },
                onLoopActivated: { clearMarkerCue() }
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
#if os(macOS)
        .onDeleteCommand {
            if rulerMeasureSelection != nil {
                rippleDeleteSelectedMeasures()
            } else {
                removeClipSelection()
            }
        }
#endif
        .sheet(isPresented: $showingGroupEditor) {
            TrackGroupEditorView()
        }
        .sheet(isPresented: $showingChangeKey) {
            ChangeKeyDialog(
                song: song,
                viewModel: viewModel,
                captureSnapshot: captureSnapshot,
                registerUndo: { actionName, before, after in
                    undoController.registerChange(
                        actionName: actionName,
                        before: before,
                        after: after,
                        apply: { snapshot in
                            applySnapshot(snapshot)
                        }
                    )
                }
            )
        }
        .sheet(isPresented: $showingMIDIDevicePicker) {
            MIDIDevicePickerView { device in
                createMIDITrack(for: device)
            }
        }
        .sheet(isPresented: $showingMIDIDeviceEditor) {
            NavigationStack {
                MIDIDeviceEditorView(device: deviceBeingEdited) { _ in
                    commitMIDIConfig()
                }
            }
        }
        .sheet(item: $sectionPendingRename) { section in
            RenameSectionSheet(currentName: section.name) { newName in
                applySectionRename(newName)
            }
        }
        .alert("Rename Track", isPresented: Binding(
            get: { trackPendingRename != nil },
            set: { if !$0 { trackPendingRename = nil } }
        )) {
            TextField("Track name", text: $renameTrackName)
            Button("Rename") {
                applyTrackRename()
            }
            Button("Cancel", role: .cancel) {
                trackPendingRename = nil
            }
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
                onPersistTimeSignatureChanges: {
                    performUndoableChange("Edit Time Signature") {
                        persistTimeSignatureChanges()
                    }
                },
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersistTempoChanges: {
                    performUndoableChange("Edit Tempo") {
                        persistTempoChanges()
                    }
                },
                showingChangeKey: $showingChangeKey,
                arrangementSlots: $arrangementSlots,
                clipTrims: $clipTrims,
                removedClips: $removedClips,
                clipGaps: $clipGaps,
                clipRegions: $clipRegions,
                loopSlotIDs: $loopSlotIDs,
                showingSongLibrary: $showingSongLibrary,
                onClearMarkerCue: { clearMarkerCue() },
                onToggleDynamicCues: toggleDynamicCues,
                currentSectionAtTime: { time in
                    displaySections.section(atTimeline: time)
                },
                onStopTransport: {
                    clearMarkerCue()
                    viewModel.stop()
                },
                onToggleLoopAtTime: { time in
                    guard let section = displaySections.section(atTimeline: time) else { return }
                    toggleLoopSection(section)
                },
                onPersistArrangement: {
                    performUndoableChange("Edit Arrangement") {
                        persistArrangement()
                    }
                },
                onUndoableChange: undoableChange,
                captureSnapshot: captureSnapshot,
                registerUndo: { actionName, before, after in
                    undoController.registerChange(
                        actionName: actionName,
                        before: before,
                        after: after,
                        apply: { snapshot in
                            applySnapshot(snapshot)
                        }
                    )
                }
            )
        }
        .toolbarBackground(AppColors.backgroundPrimary, for: .windowToolbar)
        .modifier(EditViewMacToolbarBackgroundVisibilityModifier())
#endif
    }

    private func removeClipSelection() {
        guard let clipSelection else { return }
        let trackID = clipSelection.trackID
        let selection = clipSelection

        performUndoableChange("Delete Clip") {
            switch selection {
            case .whole(let clipID, let slotID, let trackID, _):
                deleteWholeClip(clipID: clipID, slotID: slotID, trackID: trackID)
            case .range(_, let slotID, let trackID, let start, let end):
                if !displaySections.isEmpty,
                   let track = song.sortedTracks.first(where: { $0.id == trackID }),
                   let slot = arrangementSlots.first(where: { $0.id == slotID }),
                   let marker = markers.first(where: { $0.id == slot.markerID }),
                   let section = trackLaneSections(for: track).first(where: { $0.slotID == slotID }) {
                    SongArrangementStore.deleteVisibleRange(
                        slotID: slotID,
                        trackID: trackID,
                        rangeStart: start,
                        rangeEnd: end,
                        sections: trackLaneSections(for: track),
                        marker: marker,
                        markers: markers,
                        tempoChanges: normalizedTempoChanges,
                        timeSignatureChanges: normalizedTimeSignatureChanges,
                        sourceDuration: viewModel.fileDuration(for: track),
                        clipTrims: &clipTrims,
                        removedClips: &removedClips,
                        clipGaps: &clipGaps,
                        clipRegions: &clipRegions,
                        columnStart: section.columnStartSeconds
                    )
                } else if let track = song.sortedTracks.first(where: { $0.id == trackID }) {
                    deleteSourceTrackRange(track: track, rangeStart: start, rangeEnd: end)
                }
            }

            self.clipSelection = nil
            clearMarkerCue(cancellingScheduledTransition: false)
            persistArrangement()
            commitTrackArrangementChange(for: trackID)
        }
    }

    /// Ripple-deletes the ruler measure selection: removes that span from every track and shifts
    /// all later content, tempo/time-signature changes, section markers, and MIDI events earlier.
    private func rippleDeleteSelectedMeasures() {
        guard let selection = rulerMeasureSelection else { return }

        performUndoableChange("Ripple Delete") {
            let tracks = song.sortedTracks.map { track in
                TimelineRippleStore.Track(
                    id: track.id,
                    trimStart: track.trimStartSeconds,
                    trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
                    sourceDuration: viewModel.fileDuration(for: track)
                )
            }

            let result = TimelineRippleStore.rippleDeleteMeasures(
                startMeasure: selection.startMeasure,
                endMeasure: selection.endMeasure,
                markers: &arrangementMarkers,
                slots: &arrangementSlots,
                clipTrims: clipTrims,
                removedClips: removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions,
                loopSlotIDs: &loopSlotIDs,
                tempoChanges: &tempoChanges,
                timeSignatureChanges: &timeSignatureChanges,
                midiEvents: &midiEvents,
                tracks: tracks,
                defaultBPM: song.bpm ?? TempoChange.defaultBPM,
                defaultNumerator: song.timeSignatureNumerator ?? MeasureTiming.defaultNumerator,
                defaultDenominator: song.timeSignatureDenominator ?? MeasureTiming.defaultDenominator
            )

            for track in song.sortedTracks where result.emptiedTrackIDs.contains(track.id) {
                track.trimEndSeconds = track.trimStartSeconds
                viewModel.updateTrim(for: track, context: modelContext)
            }

            rulerMeasureSelection = nil
            clipSelection = nil
            clearMarkerCue(cancellingScheduledTransition: false)

            refreshTimelineLayout()
            persistTempoChanges()
            persistTimeSignatureChanges()
            persistArrangement()
            reconfigureMIDI()
            syncPlayback()
        }
    }

    private func deleteWholeClip(clipID: UUID, slotID: UUID, trackID: UUID) {
        guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return }

        let visibleSections = !displaySections.isEmpty
            ? trackLaneSections(for: track)
            : SongArrangementStore.sourceTrackDisplaySections(
                trackID: trackID,
                trimStart: track.trimStartSeconds,
                trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
                clipGaps: clipGaps,
                clipRegions: clipRegions
            )

        guard let section = visibleSections.first(where: { $0.id == clipID }) else { return }
        let siblingSections = visibleSections.filter { $0.slotID == slotID }

        if siblingSections.count > 1 {
            if !displaySections.isEmpty,
               let slot = arrangementSlots.first(where: { $0.id == slotID }),
               let marker = markers.first(where: { $0.id == slot.markerID }),
               let sourceRange = SongArrangementStore.trimmedSourceRange(
                   slot: slot,
                   trackID: trackID,
                   marker: marker,
                   markers: markers,
                   clipTrims: clipTrims,
                   sourceDuration: viewModel.fileDuration(for: track)
               ) {
                let bounds = SongArrangementStore.markerSourceRange(
                    for: marker,
                    markers: markers,
                    sourceDuration: viewModel.fileDuration(for: track)
                )
                SongArrangementStore.ensureClipRegions(
                    slotID: slotID,
                    trackID: trackID,
                    markerID: marker.id,
                    sourceRange: sourceRange,
                    boundsStart: bounds.start,
                    columnStart: section.columnStartSeconds,
                    clipGaps: clipGaps,
                    clipRegions: &clipRegions
                )
            } else {
                SongArrangementStore.ensureSourceTrackRegions(
                    trackID: track.id,
                    trimStart: track.trimStartSeconds,
                    trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
                    clipGaps: clipGaps,
                    clipRegions: &clipRegions
                )
            }
            clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }
            _ = SongArrangementStore.deleteRegion(
                regionID: clipID,
                slotID: slotID,
                trackID: trackID,
                clipTrims: &clipTrims,
                removedClips: &removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions
            )
        } else if !displaySections.isEmpty {
            SongArrangementStore.removeClip(
                slotID: slotID,
                trackID: trackID,
                clipTrims: &clipTrims,
                removedClips: &removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions
            )
        } else {
            deleteSourceTrackRange(
                track: track,
                rangeStart: section.sourceStartSeconds,
                rangeEnd: section.sourceEndSeconds
            )
        }
    }

    private func deleteSourceTrackRange(
        track: AudioTrack,
        rangeStart: TimeInterval,
        rangeEnd: TimeInterval
    ) {
        let fileDuration = viewModel.fileDuration(for: track)
        let clipStart = track.trimStartSeconds
        let clipEnd = track.trimEndSeconds ?? fileDuration
        let snapped = MeasureTiming.snapTimelineRangeToGrid(
            start: rangeStart,
            end: rangeEnd,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
        let selectionStart = max(snapped.start, clipStart)
        let selectionEnd = min(snapped.end, clipEnd)
        let minGap: TimeInterval = 0.1
        guard selectionEnd - selectionStart >= minGap else { return }

        let tolerance: TimeInterval = 0.02
        if selectionStart <= clipStart + tolerance, selectionEnd >= clipEnd - tolerance {
            track.trimEndSeconds = clipStart + minGap
        } else if selectionStart <= clipStart + tolerance {
            track.trimStartSeconds = min(selectionEnd, clipEnd - minGap)
        } else if selectionEnd >= clipEnd - tolerance {
            track.trimEndSeconds = max(selectionStart, clipStart + minGap)
        } else {
            SongArrangementStore.ensureSourceTrackRegions(
                trackID: track.id,
                trimStart: clipStart,
                trimEnd: clipEnd,
                clipGaps: clipGaps,
                clipRegions: &clipRegions
            )
            clipGaps.removeAll { $0.slotID == track.id && $0.trackID == track.id }
            _ = ClipRegionStore.deleteTimelineRange(
                slotID: track.id,
                trackID: track.id,
                rangeStart: selectionStart,
                rangeEnd: selectionEnd,
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges,
                in: &clipRegions
            )
        }
        viewModel.updateTrim(for: track, context: modelContext)
    }

    private func splitSelectedClipAtPlayhead() {
        guard let selection = clipSelection else { return }
        let trackID = selection.trackID

        performUndoableChange("Split Clip") {
            switch selection {
            case .range(let clipID, let slotID, _, let start, let end):
                let minDuration = SongArrangementStore.minimumClipDuration
                if end - start < minDuration {
                    if let rightID = performSplit(
                        clipID: clipID,
                        slotID: slotID,
                        trackID: trackID,
                        at: start
                    ) {
                        clipSelection = .whole(clipID: rightID, slotID: slotID, trackID: trackID, editTime: nil)
                        finalizeSplit(trackID: trackID)
                    }
                    return
                }

                _ = performSplit(clipID: clipID, slotID: slotID, trackID: trackID, at: end)
                if let rightID = performSplit(clipID: clipID, slotID: slotID, trackID: trackID, at: start) {
                    clipSelection = .whole(clipID: rightID, slotID: slotID, trackID: trackID, editTime: nil)
                }
                finalizeSplit(trackID: trackID)

            case .whole(let clipID, let slotID, _, let editTime):
                let splitTime = editTime ?? AudioEngineManager.shared.currentTime
                if let rightID = performSplit(
                    clipID: clipID,
                    slotID: slotID,
                    trackID: trackID,
                    at: splitTime
                ) {
                    clipSelection = .whole(clipID: rightID, slotID: slotID, trackID: trackID, editTime: nil)
                    finalizeSplit(trackID: trackID)
                }
            }
        }
    }

    @discardableResult
    private func performSplit(
        clipID: UUID,
        slotID: UUID,
        trackID: UUID,
        at splitTime: TimeInterval
    ) -> UUID? {
        guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return nil }

        let sections = clipDisplaySections(for: track)
        guard let section = sections.first(where: { $0.id == clipID })
            ?? sections.first(where: {
                splitTime >= $0.timelineStartSeconds + 0.02
                    && splitTime <= $0.timelineEndSeconds - 0.02
                    && $0.slotID == slotID
            }) else { return nil }
        guard splitTime > section.timelineStartSeconds + 0.02,
              splitTime < section.timelineEndSeconds - 0.02 else { return nil }

        if trackLaneSections(for: track).isEmpty {
            SongArrangementStore.ensureSourceTrackRegions(
                trackID: track.id,
                trimStart: track.trimStartSeconds,
                trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
                clipGaps: clipGaps,
                clipRegions: &clipRegions
            )
            clipGaps.removeAll { $0.slotID == track.id && $0.trackID == track.id }
        } else {
            materializeRegionsIfNeeded(
                slotID: slotID,
                trackID: trackID,
                section: section,
                track: track
            )
        }

        let regionID = ClipRegionStore.regions(slotID: slotID, trackID: trackID, in: clipRegions)
            .first(where: {
                splitTime > $0.timelineStartSeconds + 0.02
                    && splitTime < $0.timelineEndSeconds - 0.02
            })?.id ?? section.id

        return SongArrangementStore.splitRegion(
            regionID: regionID,
            trackID: trackID,
            at: splitTime,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges,
            clipRegions: &clipRegions
        )
    }

    private func materializeRegionsIfNeeded(
        slotID: UUID,
        trackID: UUID,
        section: ArrangementDisplaySection,
        track: AudioTrack
    ) {
        guard !ClipRegionStore.hasStoredRegions(slotID: slotID, trackID: trackID, in: clipRegions),
              let slot = arrangementSlots.first(where: { $0.id == slotID }),
              let marker = markers.first(where: { $0.id == slot.markerID }),
              let sourceRange = SongArrangementStore.trimmedSourceRange(
                  slot: slot,
                  trackID: trackID,
                  marker: marker,
                  markers: markers,
                  clipTrims: clipTrims,
                  sourceDuration: viewModel.fileDuration(for: track)
              ) else { return }

        let bounds = SongArrangementStore.markerSourceRange(
            for: marker,
            markers: markers,
            sourceDuration: viewModel.fileDuration(for: track)
        )
        SongArrangementStore.ensureClipRegions(
            slotID: slotID,
            trackID: trackID,
            markerID: marker.id,
            sourceRange: sourceRange,
            boundsStart: bounds.start,
            columnStart: section.columnStartSeconds,
            clipGaps: clipGaps,
            clipRegions: &clipRegions
        )
        clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }
    }

    private func finalizeSplit(trackID: UUID) {
        refreshTimelineLayout()
        persistArrangement()
        commitTrackArrangementChange(for: trackID)
        syncPlayback()
    }

    private func joinSelectedClipWithNext() {
        guard case .whole(let clipID, let slotID, let trackID, _) = clipSelection else { return }
        guard let track = song.sortedTracks.first(where: { $0.id == trackID }) else { return }

        let sections = clipDisplaySections(for: track)
            .filter { $0.slotID == slotID }
            .sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }

        guard let index = sections.firstIndex(where: { $0.id == clipID }),
              index + 1 < sections.count else { return }

        let nextID = sections[index + 1].id

        performUndoableChange("Join Clips") {
            if let firstSection = sections.first, !trackLaneSections(for: track).isEmpty,
               let slot = arrangementSlots.first(where: { $0.id == slotID }),
               let marker = markers.first(where: { $0.id == slot.markerID }),
               let sourceRange = SongArrangementStore.trimmedSourceRange(
                   slot: slot,
                   trackID: trackID,
                   marker: marker,
                   markers: markers,
                   clipTrims: clipTrims,
                   sourceDuration: viewModel.fileDuration(for: track)
               ) {
                let bounds = SongArrangementStore.markerSourceRange(
                    for: marker,
                    markers: markers,
                    sourceDuration: viewModel.fileDuration(for: track)
                )
                SongArrangementStore.ensureClipRegions(
                    slotID: slotID,
                    trackID: trackID,
                    markerID: marker.id,
                    sourceRange: sourceRange,
                    boundsStart: bounds.start,
                    columnStart: firstSection.columnStartSeconds,
                    clipGaps: clipGaps,
                    clipRegions: &clipRegions
                )
            } else {
                SongArrangementStore.ensureSourceTrackRegions(
                    trackID: track.id,
                    trimStart: track.trimStartSeconds,
                    trimEnd: track.trimEndSeconds ?? viewModel.fileDuration(for: track),
                    clipGaps: clipGaps,
                    clipRegions: &clipRegions
                )
            }
            clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }

            if SongArrangementStore.joinRegions(
                firstID: clipID,
                secondID: nextID,
                trackID: trackID,
                clipRegions: &clipRegions
            ) != nil {
                persistArrangement()
                commitTrackArrangementChange(for: trackID)
            }
        }
    }

    private func clearMarkerCue(cancellingScheduledTransition: Bool = true) {
        if cancellingScheduledTransition, cuedSectionID != nil {
            viewModel.cancelScheduledSectionTransition()
        }
        cuedSectionID = nil
        cueFireTime = nil
        cueFlashPhase = false
    }

    private func prepareSectionAnnouncements() {
        guard song.dynamicCuesEnabled else { return }
        sectionAnnouncer.prepare(names: displaySections.map(\.name))
    }

    private func toggleDynamicCues() {
        song.dynamicCuesEnabled.toggle()
        try? modelContext.save()
        persistProjectState()
        prepareSectionAnnouncements()
    }

    private func cueSection(_ section: ArrangementDisplaySection) {
        sectionLoop.endLoopIfActive()

        if !audioEngine.isPlaying {
            clearMarkerCue()
            viewModel.seekAndPlay(to: section.timelineStartSeconds)
            return
        }

        cuedSectionID = section.id
        cueFireTime = sectionCueFireTime(for: section)

        guard viewModel.isLoaded else { return }
        viewModel.scheduleSectionTransition(
            to: section.timelineStartSeconds,
            at: cueFireTime ?? section.timelineStartSeconds
        )
    }

    private func sectionCueFireTime(for cuedSection: ArrangementDisplaySection) -> TimeInterval {
        if let currentSection = displaySections.section(atTimeline: audioEngine.currentTime) {
            return currentSection.timelineEndSeconds
        }

        if audioEngine.currentTime < cuedSection.timelineStartSeconds {
            return cuedSection.timelineStartSeconds
        }

        return displaySections
            .map(\.timelineEndSeconds)
            .first(where: { $0 > audioEngine.currentTime })
            ?? cuedSection.timelineEndSeconds
    }

    private func fireMarkerCue() {
        guard let cueFireTime, let cuedSectionID else { return }
        guard audioEngine.currentTime >= cueFireTime else { return }
        guard let section = displaySections.first(where: { $0.id == cuedSectionID }) else {
            clearMarkerCue(cancellingScheduledTransition: false)
            return
        }

        viewModel.snapToScheduledSection(section.timelineStartSeconds)
        clearMarkerCue(cancellingScheduledTransition: false)
    }

    private func toggleLoopSection(_ section: ArrangementDisplaySection) {
        performUndoableChange("Toggle Loop") {
            sectionLoop.toggleLoop(on: section.id, loopSlotIDs: &loopSlotIDs)
            persistArrangement()
        }
    }

    private func addSection(at timelineTime: TimeInterval) {
        performUndoableChange("Add Section") {
            let snappedTime = MeasureTiming.snapToNearestBeat(
                max(0, timelineTime),
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges
            )
            let sourceTime = min(max(0, snappedTime), max(sourceDuration - 0.01, 0))

            if markers.contains(where: { abs($0.startSeconds - sourceTime) < 0.02 }) {
                return
            }

            let newMarker = ArrangementMarker(
                name: "Section \(markers.count + 1)",
                startSeconds: sourceTime,
                sortOrder: markers.count
            )
            let markerInsertIndex = markers.firstIndex(where: { $0.startSeconds > sourceTime + 0.001 })
                ?? markers.count

            arrangementMarkers.insert(newMarker, at: markerInsertIndex)

            let newSlot = ArrangementSlot(markerID: newMarker.id)
            let slotInsertIndex = displaySections.firstIndex(where: { timelineTime < $0.timelineStartSeconds - 0.001 })
                ?? arrangementSlots.count
            arrangementSlots.insert(newSlot, at: slotInsertIndex)

            refreshTimelineLayout()
            persistArrangement()
            syncPlayback()

            if let section = displaySections.first(where: { $0.markerID == newMarker.id }) {
                sectionPendingRename = section
            }
        }
    }

    private func beginRenameSection(_ section: ArrangementDisplaySection) {
        sectionPendingRename = section
    }

    private func applySectionRename(_ newName: String) {
        guard let section = sectionPendingRename else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = arrangementMarkers.firstIndex(where: { $0.id == section.markerID }) else {
            sectionPendingRename = nil
            return
        }

        performUndoableChange("Rename Section") {
            let marker = arrangementMarkers[index]
            arrangementMarkers[index] = ArrangementMarker(
                id: marker.id,
                name: trimmed,
                startSeconds: marker.startSeconds,
                sortOrder: marker.sortOrder
            )
            sectionPendingRename = nil
            refreshTimelineLayout()
            persistArrangement()
            syncPlayback()
        }
    }

    private func deleteSection(_ section: ArrangementDisplaySection) {
        performUndoableChange("Delete Section") {
            let slotID = section.slotID
            let markerID = section.markerID

            arrangementSlots.removeAll { $0.id == slotID }
            clipTrims.removeAll { $0.slotID == slotID }
            removedClips.removeAll { $0.slotID == slotID }
            clipGaps.removeAll { $0.slotID == slotID }
            clipRegions.removeAll { $0.slotID == slotID }
            loopSlotIDs.remove(slotID)
            loopSlotIDs.remove(section.id)

            if !arrangementSlots.contains(where: { $0.markerID == markerID }) {
                arrangementMarkers.removeAll { $0.id == markerID }
            }

            if cuedSectionID == section.id {
                clearMarkerCue()
            }

            refreshTimelineLayout()
            persistArrangement()
            syncPlayback()
        }
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
            onPersistTimeSignatureChanges: {
                performUndoableChange("Edit Time Signature") {
                    persistTimeSignatureChanges()
                }
            },
            tempoChanges: $tempoChanges,
            normalizedTempoChanges: normalizedTempoChanges,
            onPersistTempoChanges: {
                performUndoableChange("Edit Tempo") {
                    persistTempoChanges()
                }
            },
            showingChangeKey: $showingChangeKey,
            arrangementSlots: $arrangementSlots,
            clipTrims: $clipTrims,
            removedClips: $removedClips,
            clipGaps: $clipGaps,
            clipRegions: $clipRegions,
            loopSlotIDs: $loopSlotIDs,
            showingSongLibrary: $showingSongLibrary,
            onClearMarkerCue: { clearMarkerCue() },
            onToggleDynamicCues: toggleDynamicCues,
            onPersistArrangement: {
                performUndoableChange("Edit Arrangement") {
                    persistArrangement()
                }
            },
            onUndoableChange: undoableChange,
            captureSnapshot: captureSnapshot,
            currentSectionAtTime: { time in
                displaySections.section(atTimeline: time)
            },
            onStopTransport: {
                clearMarkerCue()
                viewModel.stop()
            },
            onToggleLoopAtTime: { time in
                guard let section = displaySections.section(atTimeline: time) else { return }
                toggleLoopSection(section)
            },
            registerUndo: { actionName, before, after in
                undoController.registerChange(
                    actionName: actionName,
                    before: before,
                    after: after,
                    apply: { snapshot in
                        applySnapshot(snapshot)
                    }
                )
            }
        )
    }

    private var dawTimeline: some View {
        stemTimeline
    }

    private var stemTimeline: some View {
        GeometryReader { geometry in
            let tracksViewportHeight = max(0, geometry.size.height - TimelineLayout.rulerTotalHeight)

            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: true) {
                    TimelinePlayheadLayer(
                        duration: timelineDuration,
                        contentWidth: timelineContentWidth,
                        displayWidth: timelineDisplayWidth,
                        height: TimelineLayout.rulerTotalHeight + tracksViewportHeight
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            timelineRulerStack
                                .frame(width: timelineDisplayWidth, height: TimelineLayout.rulerTotalHeight)

                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 0) {
                                    TimelineVerticalScrollOffsetReporter(
                                        coordinateSpaceName: timelineVerticalScrollSpace
                                    )
                                    trackTimelineScrollContent
                                        .frame(width: timelineDisplayWidth, alignment: .leading)
                                }
                            }
                            .coordinateSpace(name: timelineVerticalScrollSpace)
                            .modifier(TimelineVerticalScrollOffsetObserver(offset: $timelineVerticalScrollOffset))
                            .frame(height: tracksViewportHeight)
                        }
                    }
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
                .frame(width: timelineDisplayWidth, height: TimelineLayout.rulerTotalHeight)

            ZStack(alignment: .topLeading) {
                timelineRulerSection

                TimelineMeasureGridOverlay(
                    duration: timelineDuration,
                    tempoChanges: normalizedTempoChanges,
                    timeSignatureChanges: normalizedTimeSignatureChanges,
                    contentWidth: timelineContentWidth,
                    displayWidth: timelineDisplayWidth,
                    rulerHeight: TimelineLayout.rulerTotalHeight
                )
                .allowsHitTesting(false)
            }
            .frame(width: timelineDisplayWidth, height: TimelineLayout.rulerTotalHeight, alignment: .leading)

            if let selectionRect = rulerSelectionRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.accentColor.opacity(0.8)).frame(width: 1)
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.accentColor.opacity(0.8)).frame(width: 1)
                    }
                    .frame(width: selectionRect.width, height: TimelineLayout.rulerTotalHeight)
                    .offset(x: selectionRect.minX)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: timelineDisplayWidth, height: TimelineLayout.rulerTotalHeight, alignment: .leading)
    }

    /// Pixel bounds of the ruler measure selection highlight, if any.
    private var rulerSelectionRect: (minX: CGFloat, width: CGFloat)? {
        guard let selection = rulerMeasureSelection else { return nil }
        let startTime = MeasureTiming.timeAtStartOfMeasure(
            selection.startMeasure,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
        let endTime = MeasureTiming.timeAtStartOfMeasure(
            selection.endMeasure,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
        let startX = TimelineLayout.xPosition(
            for: startTime,
            duration: timelineDuration,
            contentWidth: timelineContentWidth
        )
        let endX = TimelineLayout.xPosition(
            for: endTime,
            duration: timelineDuration,
            contentWidth: timelineContentWidth
        )
        return (startX, max(0, endX - startX))
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
            displayWidth: timelineDisplayWidth,
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
            isPlaying: audioEngine.isPlaying,
            measureSelectionEnabled: !displaySections.isEmpty,
            onSeek: { time in
                rulerMeasureSelection = nil
                clearMarkerCue()
                seekOnTimeline(to: time)
            },
            onSelectMeasures: { startMeasure, endMeasure in
                clipSelection = nil
                rulerMeasureSelection = MeasureRangeSelection(
                    startMeasure: startMeasure,
                    endMeasure: endMeasure
                )
                isTimelineFocused = true
            },
            onCueSection: cueSection,
            onToggleLoopSection: toggleLoopSection,
            onAddSection: addSection,
            onRenameSection: beginRenameSection,
            onDeleteSection: deleteSection,
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
            Rectangle()
                .fill(Color.dawTimelineBackground)
                .frame(width: timelineDisplayWidth, height: trackAreaHeight)

            TimelineMeasureGridOverlay(
                duration: timelineDuration,
                tempoChanges: normalizedTempoChanges,
                timeSignatureChanges: normalizedTimeSignatureChanges,
                contentWidth: timelineContentWidth,
                displayWidth: timelineDisplayWidth,
                rulerHeight: 0
            )

            trackLanesContent
                .frame(width: timelineContentWidth, alignment: .leading)
        }
        .frame(width: timelineDisplayWidth, height: trackAreaHeight, alignment: .leading)
    }

    private var trackLanesContent: some View {
        LazyVStack(spacing: TimelineLayout.laneSpacing) {
            ForEach(Array(song.sortedTracks.enumerated()), id: \.element.id) { index, track in
                if let fileURL = FileStore.trackURL(for: song, track: track) {
                WaveformLaneView(
                    track: track,
                    fileURL: fileURL,
                    fileDuration: viewModel.fileDuration(for: track),
                    timelineDuration: timelineDuration,
                    timelineContentWidth: timelineContentWidth,
                    arrangementSections: trackLaneSections(for: track),
                    arrangementSlots: $arrangementSlots,
                    clipTrims: $clipTrims,
                    clipGaps: $clipGaps,
                    clipRegions: $clipRegions,
                    clipSelection: $clipSelection,
                    markers: markers,
                    tempoChanges: normalizedTempoChanges,
                    timeSignatureChanges: normalizedTimeSignatureChanges,
                    laneHeight: TimelineLayout.laneHeight,
                    trackColorIndex: index,
                    onTrimChange: {
                        performUndoableChange("Trim Track") {
                            viewModel.updateTrim(for: track, context: modelContext)
                        }
                    },
                    onCueSection: cueSection,
                    loopSlotIDs: loopSlotIDs,
                    onToggleLoopSection: toggleLoopSection,
                    onClipTrimCommitted: {
                        performUndoableChange("Trim Clip") {
                            persistArrangement()
                            commitTrackArrangementChange(for: track.id)
                        }
                    },
                    onSeek: { time in
                        AudioEngineManager.shared.seek(to: time)
                    }
                )
                .frame(width: timelineContentWidth, alignment: .leading)
                }
            }

            ForEach(Array(midiTracks.enumerated()), id: \.element.id) { index, track in
                MIDILaneView(
                    track: track,
                    device: track.device,
                    timelineDuration: timelineDuration,
                    timelineContentWidth: timelineContentWidth,
                    laneHeight: TimelineLayout.laneHeight,
                    trackColorIndex: song.sortedTracks.count + index,
                    events: $midiEvents,
                    tempoChanges: normalizedTempoChanges,
                    timeSignatureChanges: normalizedTimeSignatureChanges,
                    onCommit: commitMIDIEvents
                )
                .frame(width: timelineContentWidth, alignment: .leading)
            }
        }
        .frame(width: timelineContentWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var trackHeaderList: some View {
        VStack(spacing: TimelineLayout.laneSpacing) {
            ForEach(Array(song.sortedTracks.enumerated()), id: \.element.id) { index, track in
                TrackLaneHeaderView(
                    track: track,
                    laneHeight: TimelineLayout.laneHeight,
                    trackColorIndex: index,
                    isSelected: selectedTrackID == track.id,
                    groups: trackGroups,
                    onSelect: {
                        selectedTrackID = track.id
                        clipSelection = nil
                    },
                    onMixChange: {
                        performUndoableChange("Mix Track") {
                            viewModel.updateMix(for: track, context: modelContext)
                        }
                    },
                    onGroupChange: {
                        performUndoableChange("Assign Group") {
                            viewModel.updateGroup(for: track, context: modelContext)
                        }
                    },
                    onManageGroups: {
                        showingGroupEditor = true
                    },
                    onRename: {
                        beginRenameTrack(track)
                    },
                    onDelete: {
                        deleteAudioTrack(track)
                    }
                )
            }

            ForEach(Array(midiTracks.enumerated()), id: \.element.id) { index, track in
                MIDITrackHeaderView(
                    track: track,
                    laneHeight: TimelineLayout.laneHeight,
                    trackColorIndex: song.sortedTracks.count + index,
                    isSelected: selectedTrackID == track.id,
                    onSelect: {
                        selectedTrackID = track.id
                        clipSelection = nil
                    },
                    onConfigChange: commitMIDIConfig,
                    onSendTest: { sendMIDITest(for: track) },
                    onEditDevice: { editDevice(for: track) },
                    onDelete: { deleteMIDITrack(track) }
                )
            }
        }
        .frame(width: TimelineLayout.trackHeaderWidth)
        .background(Color.dawTrackHeaderColumnBackground)
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            audioEngine.refreshGroupMeters()
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.dawTimelineDivider)
                .frame(width: 1)
        }
    }

    private var trackAreaHeight: CGFloat {
        let count = song.sortedTracks.count + midiTracks.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * TimelineLayout.laneHeight
            + CGFloat(count - 1) * TimelineLayout.laneSpacing
    }

    private func beginRenameTrack(_ track: AudioTrack) {
        trackPendingRename = track
        renameTrackName = track.displayName
    }

    private func applyTrackRename() {
        guard let track = trackPendingRename else { return }
        let trimmed = renameTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            trackPendingRename = nil
            return
        }

        performUndoableChange("Rename Track") {
            track.displayName = trimmed
            try? modelContext.save()
            persistProjectState()
            trackPendingRename = nil
        }
    }

    private func removeArrangementData(for trackID: UUID) {
        clipTrims.removeAll { $0.trackID == trackID || $0.slotID == trackID }
        removedClips.removeAll { $0.trackID == trackID || $0.slotID == trackID }
        clipGaps.removeAll { $0.trackID == trackID || $0.slotID == trackID }
        clipRegions.removeAll { $0.trackID == trackID || $0.slotID == trackID }
        loopSlotIDs.remove(trackID)
    }

    private func deleteAudioTrack(_ track: AudioTrack) {
        let trackID = track.id

        performUndoableChange("Delete Track") {
            removeArrangementData(for: trackID)

            if selectedTrackID == trackID {
                selectedTrackID = nil
            }
            if clipSelection?.trackID == trackID {
                clipSelection = nil
            }

            song.tracks.removeAll { $0.id == trackID }
            modelContext.delete(track)

            for (index, remainingTrack) in song.sortedTracks.enumerated() {
                remainingTrack.sortOrder = index
            }

            persistProjectState()
            refreshTimelineLayout()
            syncPlayback()
            viewModel.loadSong()
        }
    }

    private func applyTempoMarker(markerID: UUID, bpm: Double) {
        guard TempoChange.validBPMRange.contains(bpm) else { return }

        performUndoableChange("Edit Tempo") {
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
    }

    private func applyTimeSignatureMarker(markerID: UUID, numerator: Int, denominator: Int) {
        guard (1...32).contains(numerator),
              TimeSignatureChange.validDenominators.contains(denominator) else { return }

        performUndoableChange("Edit Time Signature") {
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

                HStack(spacing: 6) {
                    Text("Tracks")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button { showingMIDIDevicePicker = true } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                            Text("MIDI")
                        }
                        .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
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
        Group {
            if let loadError = viewModel.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(AppColors.surfaceElevated)
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
    @Binding var clipGaps: [ArrangementClipGap]
    @Binding var clipRegions: [ClipRegion]
    @Binding var loopSlotIDs: Set<UUID>
    @Binding var showingSongLibrary: Bool
    let onClearMarkerCue: () -> Void
    let onToggleDynamicCues: () -> Void
    let currentSectionAtTime: (TimeInterval) -> ArrangementDisplaySection?
    let onStopTransport: () -> Void
    let onToggleLoopAtTime: (TimeInterval) -> Void
    let onPersistArrangement: () -> Void
    let onUndoableChange: UndoableChangeHandler
    let captureSnapshot: () -> SongEditSnapshot
    let registerUndo: (_ actionName: String, _ before: SongEditSnapshot, _ after: SongEditSnapshot) -> Void

    @State private var showingTempoToolbarEditor = false
    @Bindable private var audioEngine = AudioEngineManager.shared

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                songsButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .navigation) {
                ClickTrackEditorButton(
                    song: song,
                    viewModel: viewModel,
                    captureSnapshot: captureSnapshot,
                    registerUndo: registerUndo
                )
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                transportStrip(at: audioEngine.currentTime)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                changeKeyButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                DynamicCuesButton(isEnabled: song.dynamicCuesEnabled, onToggle: onToggleDynamicCues)
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
                songsButton
            }

            ToolbarItem(placement: .navigation) {
                ClickTrackEditorButton(
                    song: song,
                    viewModel: viewModel,
                    captureSnapshot: captureSnapshot,
                    registerUndo: registerUndo
                )
            }

            ToolbarItem(placement: .principal) {
                transportStrip(at: audioEngine.currentTime)
            }

            ToolbarItem(placement: .primaryAction) {
                changeKeyButton
            }

            ToolbarItem(placement: .primaryAction) {
                DynamicCuesButton(isEnabled: song.dynamicCuesEnabled, onToggle: onToggleDynamicCues)
            }

            if !markers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    arrangementEditorButton
                }
            }
        }
    }

    private func transportStrip(at time: TimeInterval) -> some View {
        SharedTransportStrip(
            snapshot: displaySnapshot(at: time),
            buttonSize: 44,
            isPlaying: audioEngine.isPlaying,
            isLoaded: viewModel.isLoaded,
            isLooping: sectionLoopIsActive(at: time),
            canLoop: currentSectionAtTime(time) != nil,
            onStop: onStopTransport,
            onPlay: viewModel.play,
            onPause: viewModel.pause,
            onToggleLoop: { onToggleLoopAtTime(time) },
            onTapBPM: { showingTempoToolbarEditor = true },
            onTapMeter: { showingTimeSignatureEditor = true }
        )
        .popover(isPresented: $showingTempoToolbarEditor, arrowEdge: .bottom) {
            TempoEditorMenu(
                song: song,
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersist: onPersistTempoChanges
            )
        }
        .popover(isPresented: $showingTimeSignatureEditor, arrowEdge: .bottom) {
            TimeSignatureEditorMenu(
                song: song,
                timeSignatureChanges: $timeSignatureChanges,
                normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
                onPersist: onPersistTimeSignatureChanges
            )
        }
    }

    private var songsButton: some View {
        Button {
            showingSongLibrary.toggle()
        } label: {
            Label("Songs", systemImage: "music.note.list")
        }
        .tint(showingSongLibrary ? AppColors.accent : AppColors.textSecondary)
    }

    private func displaySnapshot(at time: TimeInterval) -> TransportStatusSnapshot {
        let position = MeasureTiming.position(
            at: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
        let signature = MeasureTiming.numeratorDenominatorForMeasure(
            position.bar,
            changes: normalizedTimeSignatureChanges
        )
        let bpm = MeasureTiming.activeBPM(
            at: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )

        return TransportStatusSnapshot(
            position: MeasureTiming.formatTransportPosition(position),
            bpm: String(format: "%.1f", bpm),
            meter: "\(signature.numerator) / \(signature.denominator)",
            key: "-"
        )
    }

    private func sectionLoopIsActive(at time: TimeInterval) -> Bool {
        guard let section = currentSectionAtTime(time) else { return false }
        return loopSlotIDs.contains(section.id)
    }

    private var changeKeyButton: some View {
        Button {
            showingChangeKey = true
        } label: {
            Label("Change Key", systemImage: "key")
                .labelStyle(.iconOnly)
        }
        .appEditorToolbarPill()
        .disabled(song.sortedTracks.isEmpty)
    }

    private var arrangementEditorButton: some View {
        Button {
            showingArrangementEditor = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .appEditorToolbarPill()
        .popover(isPresented: $showingArrangementEditor, arrowEdge: .bottom) {
            ArrangementEditorMenu(
                slots: $arrangementSlots,
                clipTrims: $clipTrims,
                removedClips: $removedClips,
                clipGaps: $clipGaps,
                clipRegions: $clipRegions,
                loopSlotIDs: $loopSlotIDs,
                markers: markers,
                onPersist: onPersistArrangement,
                onUndoableChange: onUndoableChange
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
    @Binding var clipGaps: [ArrangementClipGap]
    @Binding var clipRegions: [ClipRegion]
    @Binding var loopSlotIDs: Set<UUID>
    @Binding var showingSongLibrary: Bool
    let onClearMarkerCue: () -> Void
    let onToggleDynamicCues: () -> Void
    let onPersistArrangement: () -> Void
    let onUndoableChange: UndoableChangeHandler
    let captureSnapshot: () -> SongEditSnapshot
    let currentSectionAtTime: (TimeInterval) -> ArrangementDisplaySection?
    let onStopTransport: () -> Void
    let onToggleLoopAtTime: (TimeInterval) -> Void
    let registerUndo: (_ actionName: String, _ before: SongEditSnapshot, _ after: SongEditSnapshot) -> Void

    @State private var showingTempoToolbarEditor = false
    @Bindable private var audioEngine = AudioEngineManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if audioEngine.isPlaying {
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                        transportStrip(at: audioEngine.currentTime)
                    }
                } else {
                    transportStrip(at: audioEngine.currentTime)
                }

                HStack(alignment: .center, spacing: AppSpacing.md) {
                    leadingControls
                    Spacer(minLength: 0)
                    trailingControls
                }
            }
            .padding(.horizontal)

            if let loadError = viewModel.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .background(AppColors.surfaceElevated)
    }

    private func transportStrip(at time: TimeInterval) -> some View {
        let snapshot = displaySnapshot(at: time)

        return SharedTransportStrip(
            snapshot: snapshot,
            buttonSize: 44,
            isPlaying: audioEngine.isPlaying,
            isLoaded: viewModel.isLoaded,
            isLooping: sectionLoopIsActive(at: time),
            canLoop: currentSectionAtTime(time) != nil,
            onStop: onStopTransport,
            onPlay: viewModel.play,
            onPause: viewModel.pause,
            onToggleLoop: { onToggleLoopAtTime(time) },
            onTapBPM: { showingTempoToolbarEditor = true },
            onTapMeter: { showingTimeSignatureEditor = true }
        )
        .popover(isPresented: $showingTempoToolbarEditor, arrowEdge: .bottom) {
            TempoEditorMenu(
                song: song,
                tempoChanges: $tempoChanges,
                normalizedTempoChanges: normalizedTempoChanges,
                onPersist: onPersistTempoChanges
            )
        }
        .popover(isPresented: $showingTimeSignatureEditor, arrowEdge: .bottom) {
            TimeSignatureEditorMenu(
                song: song,
                timeSignatureChanges: $timeSignatureChanges,
                normalizedTimeSignatureChanges: normalizedTimeSignatureChanges,
                onPersist: onPersistTimeSignatureChanges
            )
        }
    }

    private var leadingControls: some View {
        HStack(spacing: 8) {
            songsButton
            ClickTrackEditorButton(
                song: song,
                viewModel: viewModel,
                captureSnapshot: captureSnapshot,
                registerUndo: registerUndo
            )
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 8) {
            changeKeyButton
            DynamicCuesButton(isEnabled: song.dynamicCuesEnabled, onToggle: onToggleDynamicCues)
            if !markers.isEmpty {
                arrangementEditorButton
            }
        }
    }

    private func displaySnapshot(at time: TimeInterval) -> TransportStatusSnapshot {
        let position = MeasureTiming.position(
            at: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )
        let signature = MeasureTiming.numeratorDenominatorForMeasure(
            position.bar,
            changes: normalizedTimeSignatureChanges
        )
        let bpm = MeasureTiming.activeBPM(
            at: time,
            tempoChanges: normalizedTempoChanges,
            timeSignatureChanges: normalizedTimeSignatureChanges
        )

        return TransportStatusSnapshot(
            position: MeasureTiming.formatTransportPosition(position),
            bpm: String(format: "%.1f", bpm),
            meter: "\(signature.numerator) / \(signature.denominator)",
            key: "-"
        )
    }

    private func sectionLoopIsActive(at time: TimeInterval) -> Bool {
        guard let section = currentSectionAtTime(time) else { return false }
        return loopSlotIDs.contains(section.id)
    }

    private var changeKeyButton: some View {
        Button {
            showingChangeKey = true
        } label: {
            Label("Change Key", systemImage: "key")
                .labelStyle(.iconOnly)
        }
        .appEditorToolbarPill()
        .disabled(song.sortedTracks.isEmpty)
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
        .appEditorToolbarPill()
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
        .appEditorToolbarPill()
        .popover(isPresented: $showingArrangementEditor, arrowEdge: .bottom) {
            ArrangementEditorMenu(
                slots: $arrangementSlots,
                clipTrims: $clipTrims,
                removedClips: $removedClips,
                clipGaps: $clipGaps,
                clipRegions: $clipRegions,
                loopSlotIDs: $loopSlotIDs,
                markers: markers,
                onPersist: onPersistArrangement,
                onUndoableChange: onUndoableChange
            )
        }
    }

    private var songsButton: some View {
        Button {
            showingSongLibrary.toggle()
        } label: {
            Label("Songs", systemImage: "music.note.list")
        }
        .tint(showingSongLibrary ? AppColors.accent : AppColors.textSecondary)
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
                    .appEditorToolbarPill()
                    .tint(isSelected(numerator: preset.numerator, denominator: preset.denominator) ? AppColors.accent : .secondary)
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
                .tint(AppColors.accent)
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
    var contentWidth: CGFloat?
    var displayWidth: CGFloat?
    let rulerHeight: CGFloat

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var mappingWidth: CGFloat {
        contentWidth ?? displayWidth ?? 0
    }

    private var canvasWidth: CGFloat {
        max(mappingWidth, displayWidth ?? mappingWidth)
    }

    private var extendedMaximumTime: TimeInterval {
        guard mappingWidth > 0, canvasWidth > mappingWidth else { return safeDuration }
        return safeDuration * TimeInterval(canvasWidth / mappingWidth)
    }

    private func measureBoundaries(for contentWidth: CGFloat) -> [TimeInterval] {
        guard !tempoChanges.isEmpty, contentWidth > 0 else { return [] }
        return MeasureTiming.visibleMeasureBoundaries(
            duration: safeDuration,
            tempoChanges: tempoChanges,
            contentWidth: contentWidth,
            timeSignatureChanges: timeSignatureChanges,
            maximumTime: extendedMaximumTime
        )
    }

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, mappingWidth > 0 else { return }

            let boundaries = measureBoundaries(for: mappingWidth)
            let rulerLineColor = Color.dawMeasureGridLine
            let trackLineColor = Color.dawMeasureGridLine.opacity(0.75)
            let rulerLineEnd = min(rulerHeight, size.height)

            for time in boundaries {
                let x = TimelineLayout.xPosition(
                    for: time,
                    duration: safeDuration,
                    contentWidth: mappingWidth
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
        .frame(width: canvasWidth > 0 ? canvasWidth : nil)
        .allowsHitTesting(false)
    }
}

private struct TimelineRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let displayWidth: CGFloat
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
    let isPlaying: Bool
    let measureSelectionEnabled: Bool
    let onSeek: (TimeInterval) -> Void
    let onSelectMeasures: (Int, Int) -> Void
    let onCueSection: (ArrangementDisplaySection) -> Void
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onAddSection: (TimeInterval) -> Void
    let onRenameSection: (ArrangementDisplaySection) -> Void
    let onDeleteSection: (ArrangementDisplaySection) -> Void
    let onTimeSignatureRulerTap: (TimeInterval) -> Void
    let onEditTimeSignatureMarker: (TimeSignatureChange) -> Void
    let onDeleteTimeSignatureMarker: (TimeSignatureChange) -> Void
    let onTempoRulerTap: (TimeInterval) -> Void
    let onEditTempoMarker: (TempoChange) -> Void
    let onDeleteTempoMarker: (TempoChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var effectiveDisplayWidth: CGFloat {
        max(contentWidth, displayWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionMarkerRow
                .frame(width: effectiveDisplayWidth, height: sectionMarkerHeight)

            TimelineTimeSignatureRulerView(
                duration: safeDuration,
                contentWidth: contentWidth,
                displayWidth: effectiveDisplayWidth,
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
                displayWidth: effectiveDisplayWidth,
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
            .frame(width: effectiveDisplayWidth, height: rulerHeight)
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
        .frame(width: effectiveDisplayWidth, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.dawTimelineDivider)
                .frame(height: 1)
        }
    }

    private static let measureDragThreshold: CGFloat = 4

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard measureSelectionEnabled else { return }
                guard abs(value.location.x - value.startLocation.x) >= Self.measureDragThreshold else { return }
                reportMeasureSelection(from: value.startLocation.x, to: value.location.x)
            }
            .onEnded { value in
                let dragDistance = abs(value.location.x - value.startLocation.x)
                if measureSelectionEnabled, dragDistance >= Self.measureDragThreshold {
                    reportMeasureSelection(from: value.startLocation.x, to: value.location.x)
                } else {
                    onSeek(rulerTime(at: value.location.x))
                }
            }
    }

    private func reportMeasureSelection(from startX: CGFloat, to endX: CGFloat) {
        let firstMeasure = measureIndex(at: startX)
        let secondMeasure = measureIndex(at: endX)
        let lower = min(firstMeasure, secondMeasure)
        let upper = max(firstMeasure, secondMeasure) + 1
        onSelectMeasures(lower, upper)
    }

    private func measureIndex(at x: CGFloat) -> Int {
        MeasureTiming.measureIndex(
            at: rulerTime(at: x),
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
    }

    private func rulerTime(at x: CGFloat) -> TimeInterval {
        let clampedX = min(max(0, x), effectiveDisplayWidth)
        return safeDuration * TimeInterval(clampedX / contentWidth)
    }

    private var extendedMaximumTime: TimeInterval {
        guard contentWidth > 0, effectiveDisplayWidth > contentWidth else { return safeDuration }
        return safeDuration * TimeInterval(effectiveDisplayWidth / contentWidth)
    }

    private var tickTimes: [TimeInterval] {
        let tickInterval = tickIntervalSeconds
        let maximumTime = extendedMaximumTime
        var times: [TimeInterval] = []
        var time: TimeInterval = 0
        while time <= maximumTime + 0.0001 {
            times.append(time)
            time += tickInterval
        }
        return times
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
        TimelineSectionMarkerRowView(
            sections: sections,
            duration: safeDuration,
            contentWidth: contentWidth,
            displayWidth: effectiveDisplayWidth,
            height: sectionMarkerHeight,
            cuedSectionID: cuedSectionID,
            cueFlashPhase: cueFlashPhase,
            loopSlotIDs: loopSlotIDs,
            isPlaying: isPlaying,
            onCueSection: onCueSection,
            onToggleLoopSection: onToggleLoopSection,
            onAddSection: onAddSection,
            onRenameSection: onRenameSection,
            onDeleteSection: onDeleteSection
        )
    }

    private func formatRulerTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TimelineSectionMarkerRowView: View {
    let sections: [ArrangementDisplaySection]
    let duration: TimeInterval
    let contentWidth: CGFloat
    let displayWidth: CGFloat
    let height: CGFloat
    let cuedSectionID: UUID?
    let cueFlashPhase: Bool
    let loopSlotIDs: Set<UUID>
    let isPlaying: Bool
    let onCueSection: (ArrangementDisplaySection) -> Void
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onAddSection: (TimeInterval) -> Void
    let onRenameSection: (ArrangementDisplaySection) -> Void
    let onDeleteSection: (ArrangementDisplaySection) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: displayWidth, height: height)

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                TimelineSectionMarkerSegmentView(
                    section: section,
                    index: index,
                    duration: safeDuration,
                    contentWidth: contentWidth,
                    height: height,
                    isCued: cuedSectionID == section.id,
                    cueFlashPhase: cueFlashPhase,
                    isLoopSection: loopSlotIDs.contains(section.id),
                    isPlaying: isPlaying,
                    onCueSection: onCueSection,
                    onToggleLoopSection: onToggleLoopSection,
                    onAddSection: { time in onAddSection(time) },
                    onRenameSection: onRenameSection,
                    onDeleteSection: onDeleteSection
                )
            }

            ForEach(sections) { section in
                let x = TimelineLayout.xPosition(
                    for: section.timelineStartSeconds,
                    duration: safeDuration,
                    contentWidth: contentWidth
                )
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: 1, height: height)
                    .offset(x: x)
            }
        }
        .frame(width: displayWidth, height: height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
            let time = timelineTime(at: location.x)
            if isPlaying, let section = section(atTimeline: time) {
                onCueSection(section)
            } else if !isPlaying {
                onAddSection(time)
            }
        }
    }

    private func timelineTime(at x: CGFloat) -> TimeInterval {
        let clampedX = min(max(0, x), contentWidth)
        return safeDuration * TimeInterval(clampedX / contentWidth)
    }

    private func section(atTimeline time: TimeInterval) -> ArrangementDisplaySection? {
        sections.first { $0.timelineStartSeconds <= time && time < $0.timelineEndSeconds }
    }
}

private struct TimelineSectionMarkerSegmentView: View {
    let section: ArrangementDisplaySection
    let index: Int
    let duration: TimeInterval
    let contentWidth: CGFloat
    let height: CGFloat
    let isCued: Bool
    let cueFlashPhase: Bool
    let isLoopSection: Bool
    let isPlaying: Bool
    let onCueSection: (ArrangementDisplaySection) -> Void
    let onToggleLoopSection: (ArrangementDisplaySection) -> Void
    let onAddSection: (TimeInterval) -> Void
    let onRenameSection: (ArrangementDisplaySection) -> Void
    let onDeleteSection: (ArrangementDisplaySection) -> Void

    private var startX: CGFloat {
        TimelineLayout.xPosition(
            for: section.timelineStartSeconds,
            duration: duration,
            contentWidth: contentWidth
        )
    }

    private var segmentWidth: CGFloat {
        let endX = TimelineLayout.xPosition(
            for: section.timelineEndSeconds,
            duration: duration,
            contentWidth: contentWidth
        )
        return max(0, endX - startX)
    }

    private var sectionColor: Color {
        let colors: [Color] = [.blue, .purple, .teal, .indigo, .mint, .cyan]
        return colors[index % colors.count]
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(sectionColor.opacity(isCued && cueFlashPhase ? 0.55 : 0.25))

            HStack(spacing: 2) {
                if isLoopSection {
                    Image(systemName: "repeat")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(sectionColor)
                }
                Text(section.name.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(sectionColor)
            }
            .padding(.horizontal, 4)
            .frame(width: segmentWidth, alignment: .leading)
        }
        .frame(width: segmentWidth, height: height)
        .overlay {
            if isCued {
                Rectangle()
                    .stroke(Color.yellow.opacity(cueFlashPhase ? 1 : 0.35), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") {
                onRenameSection(section)
            }
            if isPlaying {
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
            Button("Delete Section", role: .destructive) {
                onDeleteSection(section)
            }
        }
        .onTapGesture(count: 2, coordinateSpace: .local) { location in
            if isPlaying {
                onCueSection(section)
            } else {
                let safeDuration = max(duration, 0.001)
                let clampedX = min(max(0, startX + location.x), contentWidth)
                let time = safeDuration * TimeInterval(clampedX / contentWidth)
                onAddSection(time)
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
}

private struct TimelineTimeSignatureRulerView: View {
    let duration: TimeInterval
    let contentWidth: CGFloat
    let displayWidth: CGFloat
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let height: CGFloat
    let onTap: (TimeInterval) -> Void
    let onEditMarker: (TimeSignatureChange) -> Void
    let onDeleteMarker: (TimeSignatureChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var effectiveDisplayWidth: CGFloat {
        max(contentWidth, displayWidth)
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
                let endX = index + 1 == timeSignatureSegments.count
                    ? effectiveDisplayWidth
                    : TimelineLayout.xPosition(
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
        .frame(width: effectiveDisplayWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let time = TimelineLayout.time(
                        at: min(value.location.x, contentWidth),
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
                    .appEditorToolbarPill()
                    .tint(
                        numerator == preset.numerator && denominator == preset.denominator
                            ? AppColors.accent
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
            .tint(AppColors.accent)

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
    let displayWidth: CGFloat
    let tempoChanges: [TempoChange]
    let timeSignatureChanges: [TimeSignatureChange]
    let height: CGFloat
    let onTap: (TimeInterval) -> Void
    let onEditMarker: (TempoChange) -> Void
    let onDeleteMarker: (TempoChange) -> Void

    private var safeDuration: TimeInterval {
        max(duration, 0.001)
    }

    private var effectiveDisplayWidth: CGFloat {
        max(contentWidth, displayWidth)
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
                let endX = index + 1 == tempoSegments.count
                    ? effectiveDisplayWidth
                    : TimelineLayout.xPosition(
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
        .frame(width: effectiveDisplayWidth, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    let time = TimelineLayout.time(
                        at: min(value.location.x, contentWidth),
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

private struct DynamicCuesButton: View {
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                .labelStyle(.titleAndIcon)
                .font(.body.weight(.medium))
        }
        .appEditorToolbarPill()
        .tint(isEnabled ? AppColors.accent : nil)
    }
}

private struct ClickTrackEditorButton: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var song: Song
    let viewModel: SongEditorViewModel
    let captureSnapshot: () -> SongEditSnapshot
    let registerUndo: (_ actionName: String, _ before: SongEditSnapshot, _ after: SongEditSnapshot) -> Void

    @State private var showingEditor = false
    @State private var editStartSnapshot: SongEditSnapshot?
    @State private var isGenerating = false
    @State private var generateError: String?

    var body: some View {
        Button {
            editStartSnapshot = captureSnapshot()
            showingEditor = true
        } label: {
            Image(systemName: "metronome")
        }
        .appEditorToolbarPill()
        .tint(ClickTrackFileGenerator.hasClickTrack(in: song) ? AppColors.accent : nil)
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            ClickTrackEditorMenu(
                song: song,
                viewModel: viewModel,
                isGenerating: $isGenerating,
                generateError: $generateError,
                onGenerate: generateClick
            )
        }
        .onChange(of: showingEditor) { _, isShowing in
            guard !isShowing, let before = editStartSnapshot else { return }
            let after = captureSnapshot()
            if before != after {
                registerUndo("Generate Click Track", before, after)
            }
            editStartSnapshot = nil
            generateError = nil
        }
    }

    private func generateClick() {
        isGenerating = true
        generateError = nil
        do {
            _ = try ClickTrackFileGenerator.generateAndAttach(
                to: song,
                context: modelContext,
                sourceDurationForTrack: { trackID in
                    if let track = song.sortedTracks.first(where: { $0.id == trackID }) {
                        return viewModel.fileDuration(for: track)
                    }
                    return 1
                }
            )
            viewModel.reloadSongAfterMediaChange()
            showingEditor = false
        } catch {
            generateError = error.localizedDescription
        }
        isGenerating = false
    }
}

private struct ClickTrackEditorMenu: View {
    @Bindable var song: Song
    let viewModel: SongEditorViewModel
    @Binding var isGenerating: Bool
    @Binding var generateError: String?
    let onGenerate: () -> Void

    private var canGenerate: Bool {
        let duration = ClickTrackFileGenerator.timelineDuration(
            for: song,
            sourceDurationForTrack: { trackID in
                if let track = song.sortedTracks.first(where: { $0.id == trackID }) {
                    return viewModel.fileDuration(for: track)
                }
                return 1
            }
        )
        return duration > 0 && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Click Track")
                .font(.headline)

            Button {
                onGenerate()
            } label: {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(ClickTrackFileGenerator.hasClickTrack(in: song) ? "Regenerate Click" : "Generate Click")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate)

            if let generateError {
                Text(generateError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Creates an audio track with clicks aligned to the song tempo map.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 280)
    }
}

struct RenameSectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentName: String
    let onRename: (String) -> Void

    @State private var customName: String = ""
    @FocusState private var customFieldFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: AppSpacing.xs)]

    private var trimmedCustomName: String {
        customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        ForEach(SongSectionPresets.groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.textSecondary)

                                LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xs) {
                                    ForEach(group.options, id: \.self) { option in
                                        AppChip(title: option, isSelected: option == currentName) {
                                            commit(option)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text("Custom Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColors.textSecondary)

                            HStack(spacing: AppSpacing.sm) {
                                TextField("Section name", text: $customName)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($customFieldFocused)
                                    .onSubmit {
                                        if !trimmedCustomName.isEmpty {
                                            commit(trimmedCustomName)
                                        }
                                    }

                                AppSecondaryButton(title: "Use", isEnabled: !trimmedCustomName.isEmpty) {
                                    commit(trimmedCustomName)
                                }
                            }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .frame(minWidth: 380, minHeight: 360)
                .navigationTitle("Rename Section")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    customName = currentName
                }
            }
        }
    }

    private func commit(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}

#Preview {
    EditView(
        song: Song(name: "Preview"),
        viewModel: SongEditorViewModel(song: Song(name: "Preview")),
        undoController: SongUndoController(),
        arrangementMarkers: .constant([]),
        arrangementSlots: .constant([]),
        clipTrims: .constant([]),
        removedClips: .constant([]),
        clipGaps: .constant([]),
        clipRegions: .constant([]),
        loopSlotIDs: .constant([]),
        tempoChanges: .constant([TempoChange(startMeasure: 1, bpm: 120)]),
        timeSignatureChanges: .constant([
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0)
        ]),
        midiEvents: .constant([]),
        showingSongLibrary: .constant(false)
    )
}
