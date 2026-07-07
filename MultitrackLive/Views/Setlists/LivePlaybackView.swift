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

struct LivePlaybackView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.name) private var allSongs: [Song]
    @Query(sort: \Setlist.lastOpenedAt, order: .reverse) private var allSetlists: [Setlist]

    @State private var activeSetlistID: UUID?
    @State private var didBootstrap = false
    @State private var coordinator = PlaybackCoordinator()
    @State private var viewModel = SetlistViewModel()
    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var sectionLoop = SectionLoopController()
    @State private var showingSongLibrary = false
    @State private var songToEditID: UUID?
    @State private var showingManageOutputs = false
    @State private var showingSaveSetlistAlert = false
    @State private var saveSetlistName = ""
    @State private var showingSongFolderImporter = false
    @State private var songPendingTrackImport: Song?
    @State private var songImportFeedback: SongImportFeedback?
    @State private var infoPanelHeight: CGFloat = 0
    @State private var mixerDetent: LiveGroupMixerDetent = .hidden
    @State private var headerPendingEdit: SetlistEntry?
    @State private var editHeaderTitle = ""

    private var activeSetlist: Setlist? {
        if let activeSetlistID,
           let setlist = allSetlists.first(where: { $0.id == activeSetlistID }) {
            return setlist
        }
        return allSetlists.first
    }

    private var workingSetlist: Setlist {
        guard let activeSetlist else {
            preconditionFailure("Live playback requires an active setlist")
        }
        return activeSetlist
    }

    var body: some View {
        Group {
            if let activeSetlist {
                playbackBody(for: activeSetlist)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        bootstrapSetlistIfNeeded()
                    }
            }
        }
        .focusedValue(\.liveSetlistActions, LiveSetlistActions(
            canSave: activeSetlist != nil,
            save: presentSave,
            canNew: activeSetlist != nil,
            newSetlist: createUntitledSetlist
        ))
        .alert("Save Setlist", isPresented: $showingSaveSetlistAlert) {
            TextField("Setlist name", text: $saveSetlistName)
            Button("Save") {
                saveSetlist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for this setlist.")
        }
        .alert("Edit Header", isPresented: Binding(
            get: { headerPendingEdit != nil },
            set: { if !$0 { headerPendingEdit = nil } }
        )) {
            TextField("Header title", text: $editHeaderTitle)
            Button("Save") {
                saveHeaderEdit()
            }
            Button("Cancel", role: .cancel) {
                headerPendingEdit = nil
            }
        }
    }

    private func playbackBody(for setlist: Setlist) -> some View {
        Group {
            #if os(macOS)
            LivePlaybackSidebarLayout(isVisible: $showingSongLibrary) {
                songLibraryPanel()
            } mainContent: {
                playbackMainLayout
            }
            #else
            playbackMainLayout
            #endif
        }
        #if os(macOS)
        .navigationTitle("")
        #else
        .navigationTitle(setlistDisplayName(for: setlist))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            playbackToolbar(for: setlist)
        }
        #if os(macOS)
        .toolbarBackground(AppColors.surfaceElevated, for: .windowToolbar)
        .modifier(LivePlaybackMacToolbarBackgroundVisibilityModifier())
        #endif
        .appBackground(.primary)
        .sheet(isPresented: $showingManageOutputs) {
            ManageOutputsView {
                coordinator.applyOutputRouting()
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingSongLibrary) {
            AppSheetContainer {
                NavigationStack {
                    songLibraryPanel()
                        .navigationDestination(isPresented: songEditorDestination) {
                            songEditorDestinationContent(for: setlist)
                        }
                }
            }
            .presentationDetents([.large])
        }
        #endif
        .fileImporter(
            isPresented: $showingSongFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleSongFolderImport(result)
        }
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
        .background {
            playbackMonitorSupport
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
        .onChange(of: coordinator.currentSong?.id) { _, _ in
            clearMarkerCue()
            sectionLoop.reset()
        }
        .onAppear {
            if activeSetlistID == nil {
                activeSetlistID = setlist.id
            }
            coordinator.routingProvider = {
                let channelCount = AudioOutputDeviceService.channelCount(
                    for: OutputRoutingStore.config(in: modelContext).selectedDeviceUID
                )
                return OutputRoutingStore.snapshot(in: modelContext, channelCount: channelCount)
            }
            coordinator.groupMixProvider = {
                GroupMixStore.snapshot(in: modelContext)
            }
            coordinator.configure(setlist: setlist)
            markSetlistOpened(setlist)
        }
        .onChange(of: activeSetlistID) { _, _ in
            showingSongLibrary = false
            songToEditID = nil
        }
        #if os(iOS)
        .onChange(of: showingSongLibrary) { _, isShowing in
            if !isShowing {
                songToEditID = nil
            }
        }
        #endif
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: songToEditID) { oldValue, newValue in
            if newValue != nil {
                clearMarkerCue()
                sectionLoop.reset()
                coordinator.unbindPlaybackHandlers()
                coordinator.pause()
            } else if let editedSongID = oldValue {
                coordinator.invalidateWaveformSnapshot(for: editedSongID)
            }
            handleSongEditorDismissed(newValue)
        }
        #if os(macOS)
        .navigationDestination(isPresented: songEditorDestination) {
            songEditorDestinationContent(for: setlist)
        }
        #endif
    }

    private var playbackMainLayout: some View {
        LivePlaybackMixerSplitLayout(
            mixerDetent: $mixerDetent,
            onMixChange: {
                coordinator.updateGroupMix(context: modelContext)
            },
            mainContent: {
                playbackMainSection
            }
        )
    }

    private func songLibraryPanel() -> some View {
        SongLibraryPanel(
            onEdit: { song in
                guard !song.isClickOnly else { return }
                #if os(macOS)
                showingSongLibrary = false
                #endif
                songToEditID = song.id
            },
            onDismiss: {
                showingSongLibrary = false
            },
            onRequestFolderImport: {
                showingSongLibrary = false
                showingSongFolderImporter = true
            },
            onRequestTrackImport: { song in
                showingSongLibrary = false
                songPendingTrackImport = song
            },
            onAddToSetlist: { song in
                addSong(song, at: workingSetlist.sortedEntries.count)
            }
        )
    }

    private func presentSongEditor(for song: Song) {
        guard !song.isClickOnly else { return }
        #if os(iOS)
        showingSongLibrary = true
        #else
        showingSongLibrary = false
        #endif
        songToEditID = song.id
    }

    private var songEditorDestination: Binding<Bool> {
        Binding(
            get: { songToEditID != nil },
            set: { if !$0 { songToEditID = nil } }
        )
    }

    @ToolbarContentBuilder
    private func playbackToolbar(for setlist: Setlist) -> some ToolbarContent {
        LiveSetlistToolbarContent(
            setlistSwitcher: { setlistSwitcherMenu(for: setlist) },
            coordinator: coordinator,
            audioEngine: audioEngine,
            sectionLoop: sectionLoop,
            isLoaded: coordinator.isLoaded && !coordinator.isLoadingSong,
            canLoop: !loopSections.isEmpty,
            onStop: stopPlayback,
            onPlay: coordinator.play,
            onPause: coordinator.pause,
            onToggleLoop: toggleSectionLoop,
            showingSongLibrary: $showingSongLibrary,
            showingManageOutputs: $showingManageOutputs,
            mixerDetent: $mixerDetent,
            infoPanelHeight: $infoPanelHeight
        )
    }

    private func handleSongFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            songImportFeedback = .failure(error.localizedDescription)
        case .success(let urls):
            guard let folderURL = urls.first else { return }
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
    }

    private var playbackMonitorSupport: some View {
        LivePlaybackMonitorSupport(
            cuedSectionID: cuedSectionID,
            cueFireTime: cueFireTime,
            onFireMarkerCue: fireMarkerCue,
            sectionLoop: sectionLoop,
            loopSections: loopSections,
            loopSlotIDs: loopSlotIDs,
            onLoop: snapToLoopSectionStart,
            onLoopActivated: { clearMarkerCue() }
        )
    }

    private func snapToLoopSectionStart(_ section: ArrangementDisplaySection) {
        coordinator.snapToScheduledSection(section.timelineStartSeconds)
    }

    private func toggleSectionLoop() {
        if sectionLoop.isLooping {
            sectionLoop.endLoop()
            return
        }

        guard let section = loopSections.section(atTimeline: audioEngine.currentTime) else { return }
        clearMarkerCue()
        sectionLoop.beginManualLoop(sectionID: section.id)
    }

    @ViewBuilder
    private func songEditorDestinationContent(for setlist: Setlist) -> some View {
        if let songToEditID, let song = songForEditing(id: songToEditID) {
            SongDetailView(song: song)
        }
    }

    private func handleSongEditorDismissed(_ songToEditID: UUID?) {
        guard songToEditID == nil else { return }
        coordinator.bindPlaybackHandlers()
        coordinator.loadCurrentSong()
    }

    private func setlistDisplayName(for setlist: Setlist) -> String {
        let trimmed = setlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Setlist" : trimmed
    }

    private func setlistSwitcherMenu(for setlist: Setlist) -> some View {
        Menu {
            ForEach(allSetlists) { candidate in
                Button {
                    switchToSetlist(candidate)
                } label: {
                    if candidate.id == activeSetlistID {
                        Label {
                            Text("\(candidate.name) · \(candidate.entries.count) songs")
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text("\(candidate.name) · \(candidate.entries.count) songs")
                    }
                }
            }

            Divider()

            Button {
                createUntitledSetlist()
            } label: {
                Label("New Setlist", systemImage: "plus")
            }
        } label: {
                Text(setlist.name)
                    .fontWeight(.semibold)

        }
    }

    private func bootstrapSetlistIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true

        guard allSetlists.isEmpty else {
            if activeSetlistID == nil {
                activeSetlistID = allSetlists.first?.id
            }
            return
        }

        let setlist = Setlist.untitledDraft()
        modelContext.insert(setlist)
        try? modelContext.save()
        activeSetlistID = setlist.id
    }

    private func switchToSetlist(_ setlist: Setlist) {
        guard setlist.id != activeSetlistID else { return }

        clearMarkerCue()
        sectionLoop.reset()
        coordinator.stop()
        activeSetlistID = setlist.id
        markSetlistOpened(setlist)
        coordinator.configure(setlist: setlist)
    }

    private func markSetlistOpened(_ setlist: Setlist) {
        setlist.lastOpenedAt = Date()
        try? modelContext.save()
    }

    private func stopPlayback() {
        clearMarkerCue()
        sectionLoop.reset()
        coordinator.stop()
    }

    private func presentSave() {
        if workingSetlist.isDraft {
            saveSetlistName = ""
            showingSaveSetlistAlert = true
        } else {
            try? modelContext.save()
            try? SongProjectBridge.persistShow(for: workingSetlist, context: modelContext)
        }
    }

    private func saveSetlist() {
        let trimmed = saveSetlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        workingSetlist.name = trimmed
        workingSetlist.isDraft = false
        try? modelContext.save()
        try? SongProjectBridge.persistShow(for: workingSetlist, context: modelContext)
    }

    private func createUntitledSetlist() {
        let newSetlist = Setlist.untitledDraft()
        modelContext.insert(newSetlist)
        try? modelContext.save()
        switchToSetlist(newSetlist)
    }

    private var setlistHasSongs: Bool {
        workingSetlist.sortedEntries.contains { $0.song != nil }
    }

    private var playbackMainSection: some View {
        VStack(spacing: 0) {
            if setlistHasSongs {
                currentSongSection
                    .padding(AppSpacing.md)
                    .background(AppColors.backgroundSecondary)

                Rectangle()
                    .fill(AppColors.separator)
                    .frame(height: 0.5)
            }

            setlistSection
                .background(AppColors.backgroundPrimary)
        }
    }

    private var currentSongSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let loadError = coordinator.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                LiveSetlistWaveformResizablePanel {
                    waveformContent
                }
            }
        }
    }

    @ViewBuilder
    private var waveformContent: some View {
        if setlistHasSongs {
            LiveSetlistWaveformScrollView(
                timelineItems: coordinator.timelineItems,
                currentPlaybackIndex: coordinator.currentIndex,
                songForID: { coordinator.song(for: $0) },
                waveformSnapshotForSong: { coordinator.waveformSnapshot(for: $0) },
                ensureWaveformSnapshot: { coordinator.ensureWaveformSnapshot(for: $0) },
                playheadTimeProvider: { coordinator.playbackDisplayTime },
                cuedSectionID: cuedSectionID,
                cueFlashPhase: cueFlashPhase,
                onSeek: coordinator.seek,
                onCueSection: cueSection
            )
            .overlay {
                if coordinator.isLoadingSong {
                    loadingOverlay
                }
            }
        } else if coordinator.isLoadingSong {
            LiveSetlistWaveformLoadingPlaceholder(
                message: loadingMessage(for: coordinator.currentSong)
            )
        } else {
            LiveSetlistWaveformLoadingPlaceholder()
        }
    }

    private func loadingMessage(for song: Song?) -> String {
        guard let song, song.transposeHighQuality, song.transposeSemitones != 0 else {
            return "Loading audio…"
        }
        return "Processing audio…"
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
            ProgressView(loadingMessage(for: coordinator.currentSong))
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private struct LiveSetlistWaveformLoadingPlaceholder: View {
        var message: String?

        @Environment(\.liveSetlistWaveformHeight) private var waveformHeight

        private var panelHeight: CGFloat {
            LiveSetlistWaveformMetrics.laneHeight(for: waveformHeight)
        }

        var body: some View {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(AppColors.backgroundSecondary)
                .overlay {
                    if let message {
                        ProgressView(message)
                            .tint(AppColors.accent)
                    } else {
                        RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                            .stroke(AppColors.separator, lineWidth: 0.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: panelHeight)
                .redacted(reason: message == nil ? .placeholder : [])
        }
    }

    private var setlistSection: some View {
        Group {
            if workingSetlist.sortedEntries.isEmpty {
                AppEmptyState(
                    title: "No Songs in Setlist",
                    systemImage: "music.note.list",
                    description: "Tap Add Song to build your setlist."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppSpacing.md)
                .contentShape(Rectangle())
                .contextMenu {
                    addHeaderContextMenu
                }
            } else {
                setlistList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var addHeaderContextMenu: some View {
        Button {
            addHeader()
        } label: {
            Label("Add Header", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
    }

    private var setlistList: some View {
        GeometryReader { geometry in
            List {
                Section {
                    ForEach(Array(workingSetlist.sortedEntries.enumerated()), id: \.element.id) { _, entry in
                        if entry.isHeader {
                            setlistHeaderRow(entry: entry)
                        } else if let song = entry.song {
                            setlistEntryRow(song: song, entry: entry)
                        }
                    }
                    .onMove { source, destination in
                        viewModel.moveEntries(in: workingSetlist, from: source, to: destination, context: modelContext)
                        coordinator.syncSetlist(workingSetlist)
                    }
                    .onDelete { indexSet in
                        let entries = workingSetlist.sortedEntries
                        for index in indexSet {
                            viewModel.removeEntry(entries[index], from: workingSetlist, context: modelContext)
                        }
                        coordinator.syncSetlist(workingSetlist)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: geometry.size.height)
            .contentShape(Rectangle())
            .contextMenu {
                addHeaderContextMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
    }

    private func setlistHeaderRow(entry: SetlistEntry) -> some View {
        SetlistHeaderRow(title: entry.headerTitle ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(AppColors.backgroundSecondary)
            .contextMenu {
                Button {
                    headerPendingEdit = entry
                    editHeaderTitle = entry.headerTitle ?? ""
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button("Remove from Setlist", role: .destructive) {
                    removeFromSetlist(entry)
                }
            }
    }

    private func setlistEntryRow(song: Song, entry: SetlistEntry) -> some View {
        let playbackIndex = workingSetlist.playbackIndex(for: entry) ?? 0
        let transition = workingSetlist.hasNextSong(after: entry) ? entry.transition : nil

        return Button {
            coordinator.goToSong(at: playbackIndex, autoPlay: audioEngine.isPlaying)
        } label: {
            SetlistPlaybackRow(
                song: song,
                index: playbackIndex,
                currentIndex: coordinator.currentIndex,
                isPlaying: audioEngine.isPlaying,
                transition: transition
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .focusEffectDisabled()
        #endif
        .appLinkPointer()
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                coordinator.goToSong(at: playbackIndex, autoPlay: audioEngine.isPlaying)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            if transition != nil {
                Menu("Transition to Next") {
                    ForEach(SetlistTransition.allCases) { option in
                        Button {
                            viewModel.setTransition(option, for: entry, context: modelContext)
                            coordinator.updateTransitions(from: workingSetlist)
                        } label: {
                            Label(option.label, systemImage: option.systemImage)
                        }
                    }
                }
            }

            Button {
                presentSongEditor(for: song)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(song.isClickOnly)

            Button("Remove from Setlist", role: .destructive) {
                removeFromSetlist(entry)
            }
        }
    }

    private func removeFromSetlist(_ entry: SetlistEntry) {
        viewModel.removeEntry(entry, from: workingSetlist, context: modelContext)
        coordinator.syncSetlist(workingSetlist)
    }

    private func songForEditing(id: UUID) -> Song? {
        workingSetlist.sortedEntries.compactMap(\.song).first(where: { $0.id == id })
            ?? allSongs.first(where: { $0.id == id })
    }

    private func addSong(_ song: Song, at index: Int) {
        viewModel.insertSong(song, at: index, to: workingSetlist, context: modelContext)
        coordinator.syncSetlist(workingSetlist)
    }

    private func addHeader() {
        let index = workingSetlist.sortedEntries.count
        viewModel.insertHeader(title: "New Header", at: index, to: workingSetlist, context: modelContext)
        if let entry = workingSetlist.sortedEntries.last(where: { $0.isHeader }) {
            headerPendingEdit = entry
            editHeaderTitle = entry.headerTitle ?? "New Header"
        }
    }

    private func saveHeaderEdit() {
        guard let entry = headerPendingEdit else { return }
        viewModel.renameHeader(entry, title: editHeaderTitle, context: modelContext)
        headerPendingEdit = nil
    }

    private var loopSlotIDs: Set<UUID> {
        coordinator.currentWaveformSnapshot?.loopSlotIDs ?? []
    }

    private var loopSections: [ArrangementDisplaySection] {
        coordinator.currentWaveformSnapshot?.sections ?? []
    }

    private func clearMarkerCue(cancellingScheduledTransition: Bool = true) {
        if cancellingScheduledTransition, cuedSectionID != nil {
            coordinator.cancelScheduledSectionTransition()
        }
        cuedSectionID = nil
        cueFireTime = nil
        cueFlashPhase = false
    }

    private func cueSection(_ section: ArrangementDisplaySection) {
        sectionLoop.endLoopIfActive()

        if !audioEngine.isPlaying {
            clearMarkerCue()
            coordinator.seek(to: section.timelineStartSeconds)
            return
        }

        cuedSectionID = section.id
        cueFireTime = sectionCueFireTime(for: section)

        guard coordinator.isLoaded else { return }
        coordinator.scheduleSectionTransition(
            to: section.timelineStartSeconds,
            at: cueFireTime ?? section.timelineStartSeconds
        )
    }

    private func sectionCueFireTime(for cuedSection: ArrangementDisplaySection) -> TimeInterval {
        let sections = loopSections

        if let currentSection = sections.section(atTimeline: audioEngine.currentTime) {
            return currentSection.timelineEndSeconds
        }

        return sections
            .map(\.timelineEndSeconds)
            .first(where: { $0 > audioEngine.currentTime })
            ?? cuedSection.timelineEndSeconds
    }

    private func fireMarkerCue() {
        guard let cueFireTime, let cuedSectionID else { return }
        guard audioEngine.currentTime >= cueFireTime else { return }
        guard let section = coordinator.currentWaveformSnapshot?.sections.first(where: { $0.id == cuedSectionID }) else {
            clearMarkerCue(cancellingScheduledTransition: false)
            return
        }

        coordinator.snapToScheduledSection(section.timelineStartSeconds)
        clearMarkerCue(cancellingScheduledTransition: false)
    }
}

private struct LivePlaybackMonitorSupport: View {
    let cuedSectionID: UUID?
    let cueFireTime: TimeInterval?
    let onFireMarkerCue: () -> Void
    @Bindable var sectionLoop: SectionLoopController
    let loopSections: [ArrangementDisplaySection]
    let loopSlotIDs: Set<UUID>
    let onLoop: (ArrangementDisplaySection) -> Void
    let onLoopActivated: () -> Void

    var body: some View {
        SectionCueMonitor(
            cuedSectionID: cuedSectionID,
            cueFireTime: cueFireTime,
            onFire: onFireMarkerCue
        )
        SectionLoopPlaybackSupport(
            loopController: sectionLoop,
            sections: loopSections,
            loopSlotIDs: loopSlotIDs,
            onLoop: onLoop,
            onLoopActivated: onLoopActivated
        )
    }
}

private struct SetlistHeaderRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .frame(minHeight: AppSpacing.rowMinHeight, alignment: .leading)
    }
}

private struct SetlistPlaybackRow: View {
    let song: Song
    let index: Int
    let currentIndex: Int
    let isPlaying: Bool
    var transition: SetlistTransition? = nil

    private var isFinished: Bool {
        index < currentIndex
    }

    private var isCurrent: Bool {
        index == currentIndex
    }

    private var subtitle: String? {
        if song.isClickOnly {
            return song.clickTrackSummary
        }
        if let bpm = song.bpm {
            return String(format: "%.0f BPM", bpm.rounded())
        }
        return nil
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("\(index + 1).")
                .font(isCurrent ? .subheadline.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 24, alignment: .trailing)

            if isCurrent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.accent)
                    .frame(width: 3, height: isCurrent ? 34 : 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(isCurrent ? .title2.weight(.semibold) : .body)
                    .foregroundStyle(isFinished ? AppColors.textTertiary : AppColors.textPrimary)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(isCurrent ? .subheadline : .caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                PlayingBadge(isPlaying: isPlaying)
            } else if isFinished {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(AppColors.textTertiary)
                    .font(.caption)
            }

            if let transition {
                SetlistTransitionBadge(transition: transition, size: 24)
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: isCurrent ? 60 : AppSpacing.rowMinHeight, alignment: .leading)
        .background(
            isCurrent ? AppColors.surfaceElevated : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        )
        .opacity(isFinished ? 0.55 : 1)
    }
}

private struct PlayingBadge: View {
    let isPlaying: Bool

    var body: some View {
        AppBadge(
            title: isPlaying ? "Playing" : "Paused",
            systemImage: isPlaying ? "waveform" : "pause",
            style: .accent
        )
    }
}

private struct LiveSetlistToolbarContent<Switcher: View>: ToolbarContent {
    @ViewBuilder let setlistSwitcher: Switcher
    let coordinator: PlaybackCoordinator
    @Bindable var audioEngine: AudioEngineManager
    @Bindable var sectionLoop: SectionLoopController
    let isLoaded: Bool
    let canLoop: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onToggleLoop: () -> Void
    @Binding var showingSongLibrary: Bool
    @Binding var showingManageOutputs: Bool
    @Binding var mixerDetent: LiveGroupMixerDetent
    @Binding var infoPanelHeight: CGFloat

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                setlistSwitcher
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                transportInfoBar
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                songsButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                mixerButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                setlistSwitcher
            }

            ToolbarItem(placement: .principal) {
                transportInfoBar
            }

            ToolbarItem(placement: .primaryAction) {
                songsButton
            }

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }

            ToolbarItem(placement: .automatic) {
                mixerButton
            }
        }
        #else
        ToolbarItem(placement: .navigation) {
            setlistSwitcher
        }

        ToolbarItem(placement: .principal) {
            transportInfoBar
        }

        ToolbarItem(placement: .primaryAction) {
            songsButton
        }

        ToolbarItem(placement: .automatic) {
            manageOutputsButton
        }

        ToolbarItem(placement: .automatic) {
            mixerButton
        }

        ToolbarItem(placement: .automatic) {
            EditButton()
        }
        #endif
    }

    private var transportInfoBar: some View {
        LiveSetlistNowPlayingInfoView(
            coordinator: coordinator,
            audioEngine: audioEngine,
            sectionLoop: sectionLoop,
            isLoaded: isLoaded,
            canLoop: canLoop,
            infoPanelHeight: $infoPanelHeight,
            onStop: onStop,
            onPlay: onPlay,
            onPause: onPause,
            onToggleLoop: onToggleLoop
        )
    }

    private var songsButton: some View {
        Button {
            showingSongLibrary.toggle()
        } label: {
            Label("Songs", systemImage: "music.note.list")
        }
        .tint(showingSongLibrary ? AppColors.accent : AppColors.textSecondary)
    }

    private var manageOutputsButton: some View {
        Button("Manage Outputs") {
            showingManageOutputs = true
        }
        .foregroundStyle(AppColors.textSecondary)
    }

    private var mixerButton: some View {
        Button {
            toggleMixerDrawer()
        } label: {
            Label("Mixer", systemImage: "slider.vertical.3")
        }
        .foregroundStyle(mixerDetent == .visible ? AppColors.accent : AppColors.textSecondary)
        .help("Group Mixer")
    }

    private func toggleMixerDrawer() {
        mixerDetent = mixerDetent == .hidden ? .visible : .hidden
    }
}

#if os(macOS)
private struct LivePlaybackMacToolbarBackgroundVisibilityModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}
#endif

#Preview {
    NavigationStack {
        LivePlaybackView()
    }
    .modelContainer(for: [Setlist.self, SetlistEntry.self, Song.self], inMemory: true)
}
