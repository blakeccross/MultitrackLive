import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum SongImportFeedback: Identifiable {
    case success(String)
    case failure(String)

    var id: String {
        switch self {
        case .success(let message): "success-\(message)"
        case .failure(let message): "failure-\(message)"
        }
    }

    var title: String {
        switch self {
        case .success: "Import Complete"
        case .failure: "Import Failed"
        }
    }

    var message: String {
        switch self {
        case .success(let message), .failure(let message): message
        }
    }
}

struct SongDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var song: Song
    @Query(sort: \Song.name) private var songs: [Song]

    @State private var viewModel: SongEditorViewModel?
    @State private var showingAbletonImporter = false
    @State private var abletonImportError: String?
    @State private var abletonImportSummary: String?
    @State private var showingBakePrompt = false
    @State private var showingBakeSheet = false
    @State private var shouldDismissAfterBake = false
    @State private var arrangementMarkers: [ArrangementMarker] = []
    @State private var arrangementSlots: [ArrangementSlot] = []
    @State private var clipTrims: [ArrangementClipTrim] = []
    @State private var removedClips: [ArrangementRemovedClip] = []
    @State private var clipGaps: [ArrangementClipGap] = []
    @State private var clipRegions: [ClipRegion] = []
    @State private var loopSlotIDs: Set<UUID> = []
    @State private var tempoChanges: [TempoChange] = []
    @State private var timeSignatureChanges: [TimeSignatureChange] = []
    @State private var midiEvents: [MIDIEvent] = []
    @State private var undoController = SongUndoController()
    @State private var selectedSongID: UUID?
    @State private var showingSongLibrary = false
    @State private var songPendingTrackImport: Song?
    @State private var songImportFeedback: SongImportFeedback?

    var body: some View {
        Group {
            #if os(macOS)
            LivePlaybackSidebarLayout(isVisible: $showingSongLibrary) {
                songLibraryPanel()
            } mainContent: {
                songDetailContent
            }
            #else
            songDetailContent
            #endif
        }
            .appBackground(.primary)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .fileImporter(
                isPresented: $showingAbletonImporter,
                allowedContentTypes: [AbletonProjectImporter.abletonLiveSetType],
                allowsMultipleSelection: false
            ) { result in
                handleAbletonImport(result)
            }
            .alert("Ableton Import Failed", isPresented: Binding(
                get: { abletonImportError != nil },
                set: { if !$0 { abletonImportError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(abletonImportError ?? "")
            }
            .alert("Ableton Import Complete", isPresented: Binding(
                get: { abletonImportSummary != nil },
                set: { if !$0 { abletonImportSummary = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(abletonImportSummary ?? "")
            }
            .onAppear(perform: handleAppear)
            .navigationBarBackButtonHidden(shouldPromptToBake)
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        undoController.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!undoController.canUndo)
                    .accessibilityLabel(undoController.undoActionName.map { "Undo \($0)" } ?? "Undo")

                    Button {
                        undoController.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!undoController.canRedo)
                    .accessibilityLabel(undoController.redoActionName.map { "Redo \($0)" } ?? "Redo")
                }
                #endif

                if shouldPromptToBake {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            attemptDismiss()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Bake…") {
                            showingBakeSheet = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Bake for performance?",
                isPresented: $showingBakePrompt,
                titleVisibility: .visible
            ) {
                Button("Bake Now") {
                    shouldDismissAfterBake = true
                    showingBakeSheet = true
                }
                Button("Bake Later", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text(bakePromptMessage)
            }
            .sheet(isPresented: $showingBakeSheet) {
                BakeSongSheet(song: activeSong) {
                    if shouldDismissAfterBake {
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingSongLibrary) {
                AppSheetContainer {
                    NavigationStack {
                        songLibraryPanel()
                    }
                }
                .presentationDetents([.large])
            }
            #endif
            .sheet(item: $songPendingTrackImport) { song in
                TrackImportView(song: song) { error in
                    songImportFeedback = .failure(error)
                }
            }
            .alert(item: $songImportFeedback) { feedback in
                Alert(
                    title: Text(feedback.title),
                    message: Text(feedback.message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
            #if os(macOS)
            .focusedValue(\.songEditorActions, songEditorActions)
            .focusedValue(\.songUndoActions, songUndoActions)
            #endif
            .onDisappear {
                AudioEngineManager.shared.stop()
                persistSongState()
            }
    }

    private var shouldPromptToBake: Bool {
        SongBakeStore.needsBake(for: activeSong)
    }

    private var bakePromptMessage: String {
        let trackCount = activeSong.sortedTracks.count
        return "This song has \(trackCount) tracks. Baking creates one stem per group for smoother live playback. You can still edit the original multitracks anytime."
    }

    private var activeSong: Song {
        songs.first(where: { $0.id == selectedSongID }) ?? song
    }

    private func attemptDismiss() {
        persistSongState()
        if SongBakeStore.needsBake(for: activeSong) {
            showingBakePrompt = true
        } else {
            dismiss()
        }
    }

    private var songDetailContent: some View {
        VStack(spacing: 0) {
            if let viewModel {
                ZStack {
                    EditView(
                        song: activeSong,
                        viewModel: viewModel,
                        undoController: undoController,
                        arrangementMarkers: $arrangementMarkers,
                        arrangementSlots: $arrangementSlots,
                        clipTrims: $clipTrims,
                        removedClips: $removedClips,
                        clipGaps: $clipGaps,
                        clipRegions: $clipRegions,
                        loopSlotIDs: $loopSlotIDs,
                        tempoChanges: $tempoChanges,
                        timeSignatureChanges: $timeSignatureChanges,
                        midiEvents: $midiEvents,
                        showingSongLibrary: $showingSongLibrary
                    )

                    if viewModel.isReloadingSong {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        VStack(spacing: AppSpacing.sm) {
                            ProgressView()
                                .tint(AppColors.accent)
                            Text(viewModel.isReloadingSong && activeSong.transposeHighQuality ? "Processing audio…" : "Loading audio…")
                                .font(.headline)
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        .padding(AppSpacing.xl)
                        .background(AppColors.surfaceElevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    }
                }
                .onChange(of: viewModel.isReloadingSong) { wasReloading, isReloading in
                    guard wasReloading, !isReloading else { return }
                    syncArrangementPlayback()
                    syncTempoPlayback()
                }
            } else {
                ProgressView("Loading song...")
                    .tint(AppColors.accent)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    #if os(macOS)
    private var songEditorActions: SongEditorActions {
        SongEditorActions(
            canAutoGroup: !activeSong.sortedTracks.isEmpty,
            autoGroup: {
                TrackGroupStore.autoAssignGroups(for: activeSong, in: modelContext)
            },
            importAbleton: {
                showingAbletonImporter = true
            }
        )
    }

    private var songUndoActions: SongUndoActions {
        return SongUndoActions(
            canUndo: undoController.canUndo,
            canRedo: undoController.canRedo,
            undoActionName: undoController.undoActionName,
            redoActionName: undoController.redoActionName,
            undo: { undoController.undo() },
            redo: { undoController.redo() }
        )
    }
    #endif

    private func handleAppear() {
        let audioEngine = AudioEngineManager.shared
        audioEngine.pause()
        audioEngine.onPlaybackFinished = nil
        selectedSongID = selectedSongID ?? song.id
        loadEditor(for: activeSong, forceReloadViewModel: viewModel?.song.id != activeSong.id)
    }

    private func loadEditor(for song: Song, forceReloadViewModel: Bool) {
        if viewModel == nil || forceReloadViewModel {
            let model = SongEditorViewModel(song: song)
            model.loadSong()
            viewModel = model
        }
        try? SongProjectBridge.ensureProjectFile(for: song, context: modelContext)
        guard let projectState = try? SongProjectBridge.loadProjectState(for: song) else { return }
        arrangementMarkers = projectState.markers
        arrangementSlots = projectState.arrangement.slots
        clipTrims = projectState.arrangement.clipTrims
        removedClips = projectState.arrangement.removedClips
        clipGaps = projectState.arrangement.clipGaps
        clipRegions = projectState.arrangement.clipRegions
        loopSlotIDs = projectState.arrangement.loopSlotIDs
        tempoChanges = projectState.tempoChanges
        timeSignatureChanges = projectState.timeSignatureChanges
        midiEvents = projectState.midiEvents
        migrateClipGapsIfNeeded()
        syncArrangementPlayback()
        syncTempoPlayback()
    }

    private func persistSongState() {
        try? SongProjectBridge.persist(
            song: activeSong,
            markers: arrangementMarkers,
            arrangementSlots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            loopSlotIDs: loopSlotIDs,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            midiEvents: midiEvents,
            context: modelContext
        )
    }

    private func migrateClipGapsIfNeeded() {
        guard clipRegions.isEmpty, !clipGaps.isEmpty else { return }
        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: arrangementMarkers,
            trackIDs: activeSong.sortedTracks.map(\.id),
            sourceDurationForTrack: { trackID in
                activeSong.sortedTracks.first(where: { $0.id == trackID })
                    .map { viewModel?.fileDuration(for: $0) ?? 0 } ?? 0
            }
        )
        let sourceTracks = activeSong.sortedTracks.map { track in
            (
                trackID: track.id,
                trimStart: track.trimStartSeconds,
                trimEnd: track.trimEndSeconds ?? (viewModel?.fileDuration(for: track) ?? 0)
            )
        }
        clipRegions = SongArrangementStore.migrateClipGapsToRegions(
            slots: arrangementSlots,
            clipTrims: clipTrims,
            clipGaps: clipGaps,
            removedClips: removedClips,
            inputs: inputs,
            sourceTracks: sourceTracks
        )
        clipGaps = []
        persistSongState()
    }

    private func syncArrangementPlayback() {
        guard let viewModel else { return }
        viewModel.syncArrangement(
            markers: arrangementMarkers,
            slots: arrangementSlots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
    }

    private func syncTempoPlayback() {
        guard let viewModel else { return }
        viewModel.syncTempoMap(tempoChanges, timeSignatureChanges: timeSignatureChanges)
    }

    private func switchToSong(_ nextSong: Song) {
        guard nextSong.id != activeSong.id else { return }
        persistSongState()
        AudioEngineManager.shared.stop()
        selectedSongID = nextSong.id
        undoController = SongUndoController()
        loadEditor(for: nextSong, forceReloadViewModel: true)
    }

    private func selectSongFromLibrary(_ selectedSong: Song) {
        switchToSong(selectedSong)
    }

    private func songLibraryPanel() -> some View {
        SongLibraryPanel(
            onEdit: { song in
                selectSongFromLibrary(song)
            },
            onDismiss: {
                showingSongLibrary = false
            },
            onFolderSelected: { folderURL in
                importSong(from: folderURL)
            },
            onRequestTrackImport: { song in
                #if os(iOS)
                showingSongLibrary = false
                #endif
                songPendingTrackImport = song
            },
            onAddToSetlist: { _ in }
        )
    }

    private func importSong(from folderURL: URL) {
        do {
            let importResult = try SongFolderImporter.importFromFolder(
                at: folderURL,
                context: modelContext
            )
            songImportFeedback = .success(SongFolderImporter.summaryMessage(for: importResult))
        } catch {
            songImportFeedback = .failure(error.localizedDescription)
        }
    }

    private func handleAbletonImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            abletonImportError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let importResult = try AbletonProjectImporter.importFrom(url: url)
                let markers = AbletonProjectImporter.makeMarkers(from: importResult).sortedByTime
                arrangementMarkers = markers
                try AbletonProjectImporter.apply(
                    importResult,
                    markers: markers,
                    to: activeSong,
                    context: modelContext
                )
                arrangementSlots = SongArrangementStore.defaultSlots(from: markers)
                clipTrims = []
                removedClips = []
                clipGaps = []
                clipRegions = []
                loopSlotIDs = []
                tempoChanges = [TempoChange(startMeasure: 1, bpm: importResult.bpm, sortOrder: 0)]
                timeSignatureChanges = importResult.timeSignatures
                persistSongState()
                abletonImportSummary = importSummary(for: importResult)
                syncArrangementPlayback()
                syncTempoPlayback()
            } catch {
                abletonImportError = error.localizedDescription
            }
        }
    }

    private func importSummary(for result: AbletonProjectImporter.ImportResult) -> String {
        let bpmText = String(format: "%.1f BPM", result.bpm)
        let sectionLines = result.sections.prefix(4).map { section in
            "\(section.name) at \(formatMarkerTime(section.startSeconds))"
        }
        let extraCount = max(0, result.sections.count - 4)
        var message = "Imported \(result.sections.count) sections at \(bpmText)."
        let signatures = result.timeSignatures.sortedByMeasure
        if signatures.count == 1, let initial = signatures.first {
            message += " Time signature: \(initial.displayName)."
        } else if signatures.count > 1 {
            let summary = signatures.prefix(3).map { signature in
                if signature.startMeasure == 1 {
                    return signature.displayName
                }
                return "\(signature.displayName) at measure \(signature.startMeasure)"
            }.joined(separator: ", ")
            message += " Time signatures: \(summary)"
            if signatures.count > 3 {
                message += ", …"
            }
            message += "."
        }
        message += "\n"
        message += sectionLines.joined(separator: "\n")
        if extraCount > 0 {
            message += "\n…and \(extraCount) more."
        }
        return message
    }

    private func formatMarkerTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    NavigationStack {
        SongDetailView(song: Song(name: "Preview"))
    }
}
