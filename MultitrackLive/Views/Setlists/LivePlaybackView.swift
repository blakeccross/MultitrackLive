import SwiftData
import SwiftUI

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
    @State private var showingAddSong = false
    @State private var songToEditID: UUID?
    @State private var showingManageOutputs = false
    @State private var showingSaveSetlistAlert = false
    @State private var saveSetlistName = ""

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
    }

    private func playbackBody(for setlist: Setlist) -> some View {
        VStack(spacing: 0) {
            currentSongSection
                .padding()

            Divider()

            setlistSection
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
        .toolbarBackground(.bar, for: .windowToolbar)
        .modifier(LivePlaybackMacToolbarBackgroundVisibilityModifier())
        #endif
        .sheet(isPresented: $showingManageOutputs) {
            ManageOutputsView {
                coordinator.applyOutputRouting()
            }
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
            coordinator.configure(setlist: setlist)
            markSetlistOpened(setlist)
        }
        .onChange(of: activeSetlistID) { _, _ in
            showingSongLibrary = false
            showingAddSong = false
        }
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: songToEditID) { _, newValue in
            handleSongEditorDismissed(newValue)
        }
        .navigationDestination(isPresented: songEditorDestination) {
            songEditorDestinationContent(for: setlist)
        }
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
            isLoaded: coordinator.isLoaded && !coordinator.isLoadingSong,
            onStop: stopPlayback,
            onPlay: coordinator.play,
            onPause: coordinator.pause,
            showingSongLibrary: $showingSongLibrary,
            showingAddSong: $showingAddSong,
            showingManageOutputs: $showingManageOutputs,
            onEditSong: { songToEditID = $0.id },
            onAddSong: { addSong($0, at: workingSetlist.sortedEntries.count) }
        )
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

    @ViewBuilder
    private func songEditorDestinationContent(for setlist: Setlist) -> some View {
        if let songToEditID, let song = songForEditing(id: songToEditID) {
            SongDetailView(song: song, setlistName: setlistDisplayName(for: setlist))
        }
    }

    private func handleSongEditorDismissed(_ songToEditID: UUID?) {
        guard songToEditID == nil else { return }
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
        }
    }

    private func saveSetlist() {
        let trimmed = saveSetlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        workingSetlist.name = trimmed
        workingSetlist.isDraft = false
        try? modelContext.save()
    }

    private func createUntitledSetlist() {
        let newSetlist = Setlist.untitledDraft()
        modelContext.insert(newSetlist)
        try? modelContext.save()
        switchToSetlist(newSetlist)
    }

    private var currentSongSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let loadError = coordinator.loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Group {
                    if let snapshot = coordinator.currentWaveformSnapshot {
                        LiveSetlistWaveformScrollView(
                            currentSnapshot: snapshot,
                            nextSnapshot: coordinator.nextWaveformSnapshot,
                            transitionToNext: coordinator.transitionAfterCurrentSong,
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
                    } else if coordinator.currentSong?.isClickOnly == true, coordinator.isLoaded {
                        LiveClickTrackNowPlayingView(song: coordinator.currentSong)
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
            }

            if sectionLoop.isLooping {
                Button {
                    sectionLoop.endLoop()
                } label: {
                    Label("End Loop", systemImage: "repeat.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
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

    private struct LiveClickTrackNowPlayingView: View {
        let song: Song?

        private var tempoChanges: [TempoChange] {
            guard let song else { return [] }
            return TempoStore.loadOrMigrate(for: song)
        }

        private var timeSignatureChanges: [TimeSignatureChange] {
            guard let song else { return [] }
            return TimeSignatureStore.loadOrMigrate(for: song, tempoChanges: tempoChanges)
        }

        var body: some View {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.10))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "cursorarrow.click")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(song?.name ?? "Click Track")
                            .font(.headline)
                        Text(
                            String(
                                format: "%.0f BPM • %d/%d",
                                tempoChanges.referenceBPM,
                                timeSignatureChanges.referenceNumerator,
                                timeSignatureChanges.referenceDenominator
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
        }
    }

    private struct LiveSetlistWaveformLoadingPlaceholder: View {
        var message: String?

        private let waveformHeight: CGFloat = 72

        private var laneHeight: CGFloat {
            waveformHeight + 24
        }

        var body: some View {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.10))
                .overlay {
                    if let message {
                        ProgressView(message)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: laneHeight)
                .redacted(reason: message == nil ? .placeholder : [])
        }
    }

    private var setlistSection: some View {
        setlistList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setlistList: some View {
        List {
            Section("Setlist") {
                if workingSetlist.sortedEntries.isEmpty {
                    ContentUnavailableView(
                        "No Songs in Setlist",
                        systemImage: "music.note.list",
                        description: Text("Tap Add Song to build your setlist.")
                    )
                } else {
                    ForEach(Array(workingSetlist.sortedEntries.enumerated()), id: \.element.id) { index, entry in
                        if let song = entry.song {
                            setlistEntryRow(song: song, entry: entry, index: index)
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
        }
        .listStyle(.plain)
    }

    private func setlistEntryRow(song: Song, entry: SetlistEntry, index: Int) -> some View {
        let transition = index < workingSetlist.sortedEntries.count - 1 ? entry.transition : nil

        return HStack(spacing: 12) {
            Button {
                coordinator.goToSong(at: index, autoPlay: audioEngine.isPlaying)
            } label: {
                SetlistPlaybackRow(
                    song: song,
                    index: index,
                    currentIndex: coordinator.currentIndex,
                    isPlaying: audioEngine.isPlaying
                )
            }
            .buttonStyle(.plain)

            if let transition {
                Menu {
                    ForEach(SetlistTransition.allCases) { option in
                        Button {
                            viewModel.setTransition(option, for: entry, context: modelContext)
                            coordinator.updateTransitions(from: workingSetlist)
                        } label: {
                            Label(option.label, systemImage: option.systemImage)
                        }
                    }
                } label: {
                    SetlistTransitionBadge(transition: transition, size: 24)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .contextMenu {
            Button {
                coordinator.goToSong(at: index, autoPlay: audioEngine.isPlaying)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                guard !song.isClickOnly else { return }
                songToEditID = song.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(song.isClickOnly)

            Button("Remove from Setlist", role: .destructive) {
                removeFromSetlist(entry)
            }
        }
        .listRowBackground(
            index == coordinator.currentIndex ? Color.accentColor.opacity(0.08) : nil
        )
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

private struct SetlistPlaybackRow: View {
    let song: Song
    let index: Int
    let currentIndex: Int
    let isPlaying: Bool

    private var isFinished: Bool {
        index < currentIndex
    }

    private var isCurrent: Bool {
        index == currentIndex
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(song.name)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isFinished ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                PlayingBadge(isPlaying: isPlaying)
            } else if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isFinished ? 0.55 : 1)
    }
}

private struct PlayingBadge: View {
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.caption2)
            Text(isPlaying ? "Playing" : "Paused")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor)
        .clipShape(Capsule())
    }
}

private enum SetlistAddSongKind: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case click = "Click"

    var id: String { rawValue }
}

private struct SetlistAddSongMenu: View {
    @Query(sort: \Song.name) private var songs: [Song]

    @State private var searchText = ""
    @State private var kind: SetlistAddSongKind = .songs

    let onSelect: (Song) -> Void

    private var filteredSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search songs", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Picker("Add", selection: $kind) {
                ForEach(SetlistAddSongKind.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch kind {
                case .songs:
                    songsPickerContent
                case .click:
                    ContentUnavailableView(
                        "Not Implemented",
                        systemImage: "cursorarrow.click",
                        description: Text("Click tracks will be available in a future update.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding()
        .frame(width: 300, height: 360)
    }

    @ViewBuilder
    private var songsPickerContent: some View {
        if songs.isEmpty {
            ContentUnavailableView(
                "No Songs Yet",
                systemImage: "music.note",
                description: Text("Create a song in the library first.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredSongs.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredSongs) { song in
                Button {
                    onSelect(song)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("\(song.tracks.count) tracks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

private struct LiveSetlistToolbarContent<Switcher: View>: ToolbarContent {
    @ViewBuilder let setlistSwitcher: Switcher
    let coordinator: PlaybackCoordinator
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    @Binding var showingSongLibrary: Bool
    @Binding var showingAddSong: Bool
    @Binding var showingManageOutputs: Bool
    let onEditSong: (Song) -> Void
    let onAddSong: (Song) -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                nowPlayingInfo
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                addSongButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                songsButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                setlistSwitcher
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                nowPlayingInfo
            }

            ToolbarItem(placement: .primaryAction) {
                addSongButton
            }

            ToolbarItem(placement: .primaryAction) {
                songsButton
            }

            ToolbarItem(placement: .automatic) {
                setlistSwitcher
            }

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }
        }
        #else
        ToolbarItem(placement: .principal) {
            nowPlayingInfo
        }

        ToolbarItem(placement: .primaryAction) {
            addSongButton
        }

        ToolbarItem(placement: .primaryAction) {
            songsButton
        }

        ToolbarItem(placement: .automatic) {
            setlistSwitcher
        }

        ToolbarItem(placement: .automatic) {
            manageOutputsButton
        }

        ToolbarItem(placement: .automatic) {
            EditButton()
        }
        #endif
    }

    private var nowPlayingInfo: some View {
        LiveSetlistNowPlayingInfoView(
            coordinator: coordinator,
            audioEngine: audioEngine,
            isLoaded: isLoaded,
            onStop: onStop,
            onPlay: onPlay,
            onPause: onPause
        )
    }

    private var addSongButton: some View {
        Button {
            showingAddSong = true
        } label: {
            Label("Add Song", systemImage: "plus")
        }
        .popover(isPresented: $showingAddSong, arrowEdge: .bottom) {
            SetlistAddSongMenu { song in
                onAddSong(song)
                showingAddSong = false
            }
        }
    }

    private var songsButton: some View {
        Button {
            showingSongLibrary.toggle()
        } label: {
            Label("Songs", systemImage: "music.note.list")
        }
        .popover(isPresented: $showingSongLibrary, arrowEdge: .bottom) {
            SongLibraryPanel(
                onEdit: { song in
                    guard !song.isClickOnly else { return }
                    showingSongLibrary = false
                    onEditSong(song)
                },
                onDismiss: {
                    showingSongLibrary = false
                }
            )
            .frame(width: 300, height: 420)
        }
    }

    private var manageOutputsButton: some View {
        Button("Manage Outputs") {
            showingManageOutputs = true
        }
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
