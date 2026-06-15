import SwiftData
import SwiftUI

private enum SetlistDropMetrics {
    static let inactiveDropHeight: CGFloat = 12
    static let activeDropHeight: CGFloat = 56
    static let targetClearDelayMs: UInt64 = 150
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.9)
}

struct LivePlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.name) private var allSongs: [Song]
    @Query(sort: \Setlist.createdAt, order: .reverse) private var allSetlists: [Setlist]

    let setlist: Setlist

    @State private var activeSetlistID: UUID
    @State private var coordinator = PlaybackCoordinator()
    @State private var viewModel = SetlistViewModel()
    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var activeLoopSectionID: UUID?
    @State private var suppressedLoopSectionIDs: Set<UUID> = []
    @State private var showingSongLibrary = false
    @State private var songSearchText = ""
    @State private var songDropInsertionIndex: Int?
    @State private var clearDropTargetTask: Task<Void, Never>?
    @State private var songToEditID: UUID?
    @State private var showingManageOutputs = false
    @State private var showingNewSetlistAlert = false
    @State private var newSetlistName = ""

    init(setlist: Setlist) {
        self.setlist = setlist
        _activeSetlistID = State(initialValue: setlist.id)
    }

    private var activeSetlist: Setlist {
        allSetlists.first(where: { $0.id == activeSetlistID }) ?? setlist
    }

    var body: some View {
        VStack(spacing: 0) {
            currentSongSection
                .padding()

            Divider()

            setlistSection
        }
        .navigationTitle(activeSetlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                setlistSwitcherMenu
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Stop") {
                    clearMarkerCue()
                    activeLoopSectionID = nil
                    suppressedLoopSectionIDs.removeAll()
                    coordinator.stop()
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSongLibrary.toggle()
                } label: {
                    Label("Songs", systemImage: showingSongLibrary ? "sidebar.right" : "music.note.list")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Manage Outputs") {
                    showingManageOutputs = true
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .automatic) {
                EditButton()
            }
            #endif
        }
        .sheet(isPresented: $showingManageOutputs) {
            ManageOutputsView {
                coordinator.applyOutputRouting()
            }
        }
        .alert("New Setlist", isPresented: $showingNewSetlistAlert) {
            TextField("Setlist name", text: $newSetlistName)
            Button("Create") {
                createSetlist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for your live setlist.")
        }
        .background {
            SectionCueMonitor(
                cuedSectionID: cuedSectionID,
                cueFireTime: cueFireTime,
                onFire: fireMarkerCue
            )
            SectionLoopMonitor(
                activeLoopSection: activeLoopSection,
                onLoop: fireSectionLoop
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
        .onChange(of: coordinator.currentSong?.id) { _, _ in
            clearMarkerCue()
            activeLoopSectionID = nil
            suppressedLoopSectionIDs.removeAll()
        }
        .onChange(of: audioEngine.currentTime) { _, time in
            clearSuppressedLoopsIfLeftSection(at: time)
            activateLoopIfNeeded(at: time)
        }
        .onAppear {
            coordinator.routingProvider = {
                let channelCount = AudioOutputDeviceService.channelCount(
                    for: OutputRoutingStore.config(in: modelContext).selectedDeviceUID
                )
                return OutputRoutingStore.snapshot(in: modelContext, channelCount: channelCount)
            }
            coordinator.configure(setlist: activeSetlist)
        }
        .onChange(of: activeSetlistID) { _, _ in
            songSearchText = ""
            showingSongLibrary = false
            songDropInsertionIndex = nil
            clearDropTargetTask?.cancel()
        }
        .onDisappear {
            clearMarkerCue()
            activeLoopSectionID = nil
            suppressedLoopSectionIDs.removeAll()
            coordinator.stop()
        }
        .navigationDestination(isPresented: Binding(
            get: { songToEditID != nil },
            set: { if !$0 { songToEditID = nil } }
        )) {
            if let songToEditID, let song = songForEditing(id: songToEditID) {
                SongDetailView(song: song, initialTab: .edit)
            }
        }
    }

    private var setlistSwitcherMenu: some View {
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
                newSetlistName = ""
                showingNewSetlistAlert = true
            } label: {
                Label("New Setlist", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(activeSetlist.name)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func switchToSetlist(_ setlist: Setlist) {
        guard setlist.id != activeSetlistID else { return }

        clearMarkerCue()
        activeLoopSectionID = nil
        suppressedLoopSectionIDs.removeAll()
        coordinator.stop()
        activeSetlistID = setlist.id
        coordinator.configure(setlist: setlist)
    }

    private func createSetlist() {
        let trimmed = newSetlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newSetlist = Setlist(name: trimmed)
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
            } else if let snapshot = coordinator.currentWaveformSnapshot {
                LiveSetlistWaveformScrollView(
                    currentSnapshot: snapshot,
                    nextSnapshot: coordinator.nextWaveformSnapshot,
                    transitionToNext: coordinator.transitionAfterCurrentSong,
                    cuedSectionID: cuedSectionID,
                    cueFlashPhase: cueFlashPhase,
                    onSeek: coordinator.seek,
                    onCueSection: cueSection
                )
            }

            TransportControls(
                audioEngine: audioEngine,
                isLoaded: coordinator.isLoaded,
                duration: audioEngine.duration,
                onPlay: coordinator.play,
                onPause: coordinator.pause,
                onStop: {
                    clearMarkerCue()
                    activeLoopSectionID = nil
                    suppressedLoopSectionIDs.removeAll()
                    coordinator.stop()
                }
            )
            .frame(maxWidth: .infinity)

            if activeLoopSectionID != nil {
                Button {
                    endLoop()
                } label: {
                    Label("End Loop", systemImage: "repeat.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            HStack(spacing: 24) {
                Button {
                    coordinator.goToPreviousSong(autoPlay: audioEngine.isPlaying)
                } label: {
                    Label("Previous", systemImage: "backward.fill")
                }
                .disabled(coordinator.previousSong == nil)

                Spacer()

                Button {
                    coordinator.goToNextSong(autoPlay: audioEngine.isPlaying)
                } label: {
                    Label("Next", systemImage: "forward.fill")
                }
                .disabled(coordinator.nextSong == nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private var filteredSongs: [Song] {
        let query = songSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allSongs }
        return allSongs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var setlistSection: some View {
        HStack(spacing: 0) {
            setlistList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingSongLibrary {
                Divider()
                songLibraryPanel
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingSongLibrary)
    }

    private var setlistList: some View {
        List {
            Section("Setlist") {
                if activeSetlist.sortedEntries.isEmpty {
                    SetlistSongDropSlot(
                        index: 0,
                        insertionIndex: $songDropInsertionIndex,
                        prominent: true,
                        listRowStyled: true,
                        onDrop: { addSongFromDrag($0, at: 0) },
                        onTargetChanged: updateDropTarget
                    )

                    ContentUnavailableView(
                        "No Songs in Setlist",
                        systemImage: "music.note.list",
                        description: Text("Drag songs from the library to add them.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(activeSetlist.sortedEntries.enumerated()), id: \.element.id) { index, entry in
                        if let song = entry.song {
                            setlistEntryRow(
                                song: song,
                                entry: entry,
                                index: index
                            )
                        }
                    }
                    .onMove { source, destination in
                        viewModel.moveEntries(in: activeSetlist, from: source, to: destination, context: modelContext)
                        coordinator.syncSetlist(activeSetlist)
                    }
                    .onDelete { indexSet in
                        let entries = activeSetlist.sortedEntries
                        for index in indexSet {
                            viewModel.removeEntry(entries[index], from: activeSetlist, context: modelContext)
                        }
                        coordinator.syncSetlist(activeSetlist)
                    }

                    SetlistSongDropSlot(
                        index: activeSetlist.sortedEntries.count,
                        insertionIndex: $songDropInsertionIndex,
                        listRowStyled: true,
                        onDrop: { addSongFromDrag($0, at: activeSetlist.sortedEntries.count) },
                        onTargetChanged: updateDropTarget
                    )
                }
            }
        }
        .listStyle(.plain)
        .onChange(of: showingSongLibrary) { _, isShowing in
            if !isShowing {
                clearDropTargetTask?.cancel()
                songDropInsertionIndex = nil
            }
        }
    }

    private func setlistEntryRow(song: Song, entry: SetlistEntry, index: Int) -> some View {
        VStack(spacing: 0) {
            SetlistSongDropSlot(
                index: index,
                insertionIndex: $songDropInsertionIndex,
                onDrop: { addSongFromDrag($0, at: index) },
                onTargetChanged: updateDropTarget
            )

            SetlistPlaybackRow(
                song: song,
                index: index,
                currentIndex: coordinator.currentIndex,
                isPlaying: audioEngine.isPlaying,
                transition: index < activeSetlist.sortedEntries.count - 1 ? entry.transition : nil,
                onTransitionChange: { transition in
                    viewModel.setTransition(transition, for: entry, context: modelContext)
                    coordinator.updateTransitions(from: activeSetlist)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if let songIndex = coordinator.songs.firstIndex(where: { $0.id == song.id }) {
                    coordinator.goToSong(at: songIndex, autoPlay: audioEngine.isPlaying)
                }
            }
        }
        .contextMenu {
            Button {
                songToEditID = song.id
            } label: {
                Label("Edit Song", systemImage: "pencil")
            }

            Button("Remove from Setlist", role: .destructive) {
                removeFromSetlist(entry)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(
            index == coordinator.currentIndex ? Color.accentColor.opacity(0.08) : nil
        )
    }

    private func removeFromSetlist(_ entry: SetlistEntry) {
        viewModel.removeEntry(entry, from: activeSetlist, context: modelContext)
        coordinator.syncSetlist(activeSetlist)
    }

    private func songForEditing(id: UUID) -> Song? {
        activeSetlist.sortedEntries.compactMap(\.song).first(where: { $0.id == id })
            ?? allSongs.first(where: { $0.id == id })
    }

    private func updateDropTarget(_ isTargeted: Bool, at index: Int) {
        clearDropTargetTask?.cancel()

        if isTargeted {
            withAnimation(SetlistDropMetrics.spring) {
                songDropInsertionIndex = index
            }
            return
        }

        clearDropTargetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(SetlistDropMetrics.targetClearDelayMs))
            guard !Task.isCancelled else { return }
            if songDropInsertionIndex == index {
                withAnimation(SetlistDropMetrics.spring) {
                    songDropInsertionIndex = nil
                }
            }
        }
    }

    private var songLibraryPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Songs")
                    .font(.headline)
                Spacer()
                Button {
                    showingSongLibrary = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide song library")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            TextField("Search songs", text: $songSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Group {
                if allSongs.isEmpty {
                    ContentUnavailableView(
                        "No Songs Available",
                        systemImage: "music.note",
                        description: Text("Create songs in the Songs tab first.")
                    )
                } else if filteredSongs.isEmpty {
                    ContentUnavailableView.search(text: songSearchText)
                } else {
                    List(filteredSongs) { song in
                        SongLibraryDragRow(song: song)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(.background)
    }

    @discardableResult
    private func addSongFromDrag(_ items: [String], at index: Int) -> Bool {
        guard let idString = items.first, let songID = UUID(uuidString: idString) else { return false }
        guard let song = allSongs.first(where: { $0.id == songID }) else { return false }

        clearDropTargetTask?.cancel()
        withAnimation(SetlistDropMetrics.spring) {
            songDropInsertionIndex = nil
        }
        viewModel.insertSong(song, at: index, to: activeSetlist, context: modelContext)
        coordinator.syncSetlist(activeSetlist)
        return true
    }

    private var loopSlotIDs: Set<UUID> {
        coordinator.currentWaveformSnapshot?.loopSlotIDs ?? []
    }

    private var activeLoopSection: ArrangementDisplaySection? {
        guard let activeLoopSectionID else { return nil }
        return coordinator.currentWaveformSnapshot?.sections.first(where: { $0.id == activeLoopSectionID })
    }

    private func clearSuppressedLoopsIfLeftSection(at time: TimeInterval) {
        guard !suppressedLoopSectionIDs.isEmpty else { return }
        guard let sections = coordinator.currentWaveformSnapshot?.sections else { return }

        for sectionID in suppressedLoopSectionIDs {
            guard let section = sections.first(where: { $0.id == sectionID }) else {
                suppressedLoopSectionIDs.remove(sectionID)
                continue
            }
            let inSection = time >= section.timelineStartSeconds && time < section.timelineEndSeconds
            if !inSection {
                suppressedLoopSectionIDs.remove(sectionID)
            }
        }
    }

    private func activateLoopIfNeeded(at time: TimeInterval) {
        guard activeLoopSectionID == nil else { return }
        guard !loopSlotIDs.isEmpty else { return }
        guard let sections = coordinator.currentWaveformSnapshot?.sections else { return }

        if let section = sections.first(where: {
            loopSlotIDs.contains($0.id)
                && !suppressedLoopSectionIDs.contains($0.id)
                && time >= $0.timelineStartSeconds
                && time < $0.timelineEndSeconds
        }) {
            activeLoopSectionID = section.id
            clearMarkerCue()
        }
    }

    private func fireSectionLoop() {
        guard let section = activeLoopSection else { return }
        coordinator.snapToScheduledSection(section.timelineStartSeconds)
    }

    private func endLoop() {
        if let activeLoopSectionID {
            suppressedLoopSectionIDs.insert(activeLoopSectionID)
        }
        activeLoopSectionID = nil
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
        if activeLoopSectionID != nil {
            endLoop()
        }

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
        let sections = coordinator.currentWaveformSnapshot?.sections ?? []

        if let currentSection = sections.first(where: {
            audioEngine.currentTime >= $0.timelineStartSeconds
                && audioEngine.currentTime < $0.timelineEndSeconds
        }) {
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

private struct SetlistPlaybackRow: View {
    let song: Song
    let index: Int
    let currentIndex: Int
    let isPlaying: Bool
    let transition: SetlistTransition?
    let onTransitionChange: (SetlistTransition) -> Void

    private var isFinished: Bool {
        index < currentIndex
    }

    private var isCurrent: Bool {
        index == currentIndex
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Text(song.name)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isFinished ? .secondary : .primary)
                .lineLimit(2)

            Spacer()

            if let transition {
                Menu {
                    ForEach(SetlistTransition.allCases) { option in
                        Button {
                            onTransitionChange(option)
                        } label: {
                            Label(option.label, systemImage: option.systemImage)
                        }
                    }
                } label: {
                    SetlistTransitionBadge(transition: transition, size: 24)
                }
                .menuStyle(.borderlessButton)
            }

            if isCurrent {
                PlayingBadge(isPlaying: isPlaying)
            } else if isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
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

private struct SetlistDropPlaceholder: View {
    var isActive: Bool
    var inactiveLabel = "Drop song here"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(isActive ? "Release to add song" : inactiveLabel)
                .font(.subheadline)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(isActive ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color.accentColor.opacity(isActive ? 0.65 : 0.25),
                    style: StrokeStyle(lineWidth: isActive ? 2 : 1, dash: isActive ? [6, 4] : [4, 4])
                )
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: SetlistDropMetrics.activeDropHeight)
    }
}

private struct SetlistSongDropSlot: View {
    let index: Int
    @Binding var insertionIndex: Int?
    var prominent = false
    var listRowStyled = false
    let onDrop: ([String]) -> Bool
    let onTargetChanged: (Bool, Int) -> Void

    private var isActive: Bool {
        insertionIndex == index
    }

    private var height: CGFloat {
        if prominent { return 88 }
        return isActive ? SetlistDropMetrics.activeDropHeight : SetlistDropMetrics.inactiveDropHeight
    }

    var body: some View {
        ZStack {
            if isActive {
                SetlistDropPlaceholder(isActive: true)
            } else if prominent {
                SetlistDropPlaceholder(isActive: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .modifier(SetlistDropSlotListRowStyle(enabled: listRowStyled))
        .animation(SetlistDropMetrics.spring, value: isActive)
        .dropDestination(for: String.self) { items, _ in
            onDrop(items)
        } isTargeted: { isTargeted in
            onTargetChanged(isTargeted, index)
        }
    }
}

private struct SetlistDropSlotListRowStyle: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            content
        }
    }
}

private struct SongLibraryDragRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(song.tracks.count) tracks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .draggable(song.id.uuidString) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                Text(song.name)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    NavigationStack {
        LivePlaybackView(setlist: Setlist(name: "Sunday"))
    }
    .modelContainer(for: [Setlist.self, SetlistEntry.self, Song.self], inMemory: true)
}
