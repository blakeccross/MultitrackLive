import SwiftData
import SwiftUI

private enum SetlistDropMetrics {
    static let inactiveDropHeight: CGFloat = 12
    static let inactiveDropHitHeight: CGFloat = 28
    static let activeDropHeight: CGFloat = 56
    static let targetClearDelayMs: UInt64 = 150
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.9)
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
    @State private var activeLoopSectionID: UUID?
    @State private var suppressedLoopSectionIDs: Set<UUID> = []
    @State private var showingSongLibrary = false
    @State private var songDropInsertionIndex: Int?
    @State private var clearDropTargetTask: Task<Void, Never>?
    @State private var songToEditID: UUID?
    @State private var showingManageOutputs = false

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
    }

    private func playbackBody(for setlist: Setlist) -> some View {
        VStack(spacing: 0) {
            currentSongSection
                .padding()

            Divider()

            setlistSection
        }
        .navigationTitle(setlistDisplayName(for: setlist))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            LiveSetlistToolbarContent(
                setlistSwitcher: { setlistSwitcherMenu(for: setlist) },
                tempoDisplay: currentSongTempoDisplay,
                timeSignatureDisplay: currentSongTimeSignatureDisplay,
                audioEngine: audioEngine,
                isLoaded: coordinator.isLoaded && !coordinator.isLoadingSong,
                onStop: stopPlayback,
                onPlay: coordinator.play,
                onPause: coordinator.pause,
                showingSongLibrary: $showingSongLibrary,
                showingManageOutputs: $showingManageOutputs,
                onEditSong: { songToEditID = $0.id }
            )
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
            songDropInsertionIndex = nil
            clearDropTargetTask?.cancel()
        }
        .onDisappear {
            stopPlayback()
        }
        .navigationDestination(isPresented: Binding(
            get: { songToEditID != nil },
            set: { if !$0 { songToEditID = nil } }
        )) {
            if let songToEditID, let song = songForEditing(id: songToEditID) {
                SongDetailView(song: song, setlistName: setlistDisplayName(for: setlist))
            }
        }
    }

    private func setlistDisplayName(for setlist: Setlist) -> String {
        let trimmed = setlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Setlist" : trimmed
    }

    private var currentSongTempoDisplay: String {
        guard let song = coordinator.currentSong else { return "-" }
        let tempoChanges = TempoStore.loadOrMigrate(for: song)
        let normalized = tempoChanges.normalizedEnsuringInitialMarker(
            defaultBPM: song.bpm ?? TempoChange.defaultBPM
        )
        return String(format: "%.0f BPM", normalized.referenceBPM)
    }

    private var currentSongTimeSignatureDisplay: String {
        guard let song = coordinator.currentSong else { return "-" }
        return song.timeSignatureDisplay ?? "4/4"
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
        activeLoopSectionID = nil
        suppressedLoopSectionIDs.removeAll()
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
        activeLoopSectionID = nil
        suppressedLoopSectionIDs.removeAll()
        coordinator.stop()
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
                    } else if coordinator.isLoadingSong {
                        LiveSetlistWaveformLoadingPlaceholder(
                            message: loadingMessage(for: coordinator.currentSong)
                        )
                    } else {
                        LiveSetlistWaveformLoadingPlaceholder()
                    }
                }
            }

            TransportElapsedTimeLabel(audioEngine: audioEngine, duration: audioEngine.duration)
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
                    SetlistSongDropSlot(
                        index: 0,
                        insertionIndex: $songDropInsertionIndex,
                        prominent: true,
                        listRowStyled: true,
                        onDrop: { addSongFromDrag($0, at: 0) },
                        onTargetChanged: updateDropTarget,
                        onSelectSong: { addSong($0, at: 0) }
                    )

                    ContentUnavailableView(
                        "No Songs in Setlist",
                        systemImage: "music.note.list",
                        description: Text("Open the Songs menu, drag songs here, or tap to add.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(workingSetlist.sortedEntries.enumerated()), id: \.element.id) { index, entry in
                        if let song = entry.song {
                            setlistEntryRow(
                                song: song,
                                entry: entry,
                                index: index
                            )
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

                    SetlistSongDropSlot(
                        index: workingSetlist.sortedEntries.count,
                        insertionIndex: $songDropInsertionIndex,
                        listRowStyled: true,
                        onDrop: { addSongFromDrag($0, at: workingSetlist.sortedEntries.count) },
                        onTargetChanged: updateDropTarget,
                        onSelectSong: { addSong($0, at: workingSetlist.sortedEntries.count) }
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
        let dropActive = songDropInsertionIndex == index
        let row = setlistPlaybackRowContent(song: song, entry: entry, index: index)
        let dropSlot = SetlistSongDropSlot(
            index: index,
            insertionIndex: $songDropInsertionIndex,
            onDrop: { addSongFromDrag($0, at: index) },
            onTargetChanged: updateDropTarget,
            onSelectSong: { addSong($0, at: index) }
        )

        return Group {
            if dropActive {
                VStack(spacing: 0) {
                    dropSlot
                    row
                }
            } else {
                row
                    .overlay(alignment: .top) {
                        dropSlot
                            .offset(y: -SetlistDropMetrics.inactiveDropHitHeight / 2)
                    }
            }
        }
        .contextMenu {
            Button {
                coordinator.goToSong(at: index, autoPlay: audioEngine.isPlaying)
            } label: {
                Label("Play", systemImage: "play.fill")
            }

            Button {
                songToEditID = song.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button("Remove from Setlist", role: .destructive) {
                removeFromSetlist(entry)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
            index == coordinator.currentIndex ? Color.accentColor.opacity(0.08) : nil
        )
    }

    private func setlistPlaybackRowContent(song: Song, entry: SetlistEntry, index: Int) -> some View {
        SetlistPlaybackRow(
            song: song,
            index: index,
            currentIndex: coordinator.currentIndex,
            isPlaying: audioEngine.isPlaying,
            transition: index < workingSetlist.sortedEntries.count - 1 ? entry.transition : nil,
            onTransitionChange: { transition in
                viewModel.setTransition(transition, for: entry, context: modelContext)
                coordinator.updateTransitions(from: workingSetlist)
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.goToSong(at: index, autoPlay: audioEngine.isPlaying)
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

    private func addSong(_ song: Song, at index: Int) {
        clearDropTargetTask?.cancel()
        withAnimation(SetlistDropMetrics.spring) {
            songDropInsertionIndex = nil
        }
        viewModel.insertSong(song, at: index, to: workingSetlist, context: modelContext)
        coordinator.syncSetlist(workingSetlist)
    }

    @discardableResult
    private func addSongFromDrag(_ items: [String], at index: Int) -> Bool {
        guard let idString = items.first, let songID = UUID(uuidString: idString) else { return false }
        guard let song = allSongs.first(where: { $0.id == songID }) else { return false }
        addSong(song, at: index)
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

private struct SetlistSongDropSlot: View {
    let index: Int
    @Binding var insertionIndex: Int?
    var prominent = false
    var listRowStyled = false
    let onDrop: ([String]) -> Bool
    let onTargetChanged: (Bool, Int) -> Void
    let onSelectSong: (Song) -> Void

    @State private var showingAddMenu = false

    private var isActive: Bool {
        insertionIndex == index
    }

    private var height: CGFloat {
        if prominent { return 88 }
        return isActive ? SetlistDropMetrics.activeDropHeight : SetlistDropMetrics.inactiveDropHeight
    }

    private var hitHeight: CGFloat {
        prominent ? height : max(height, SetlistDropMetrics.inactiveDropHitHeight)
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: hitHeight)
            .overlay {
                ZStack {
                    if isActive {
                        SetlistDropPlaceholder(isActive: true)
                    } else if prominent {
                        SetlistDropPlaceholder(isActive: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .modifier(SetlistDropSlotListRowStyle(enabled: listRowStyled))
            .animation(SetlistDropMetrics.spring, value: isActive)
            .onTapGesture {
                showingAddMenu = true
            }
            .popover(isPresented: $showingAddMenu, arrowEdge: .bottom) {
                SetlistAddSongMenu { song in
                    onSelectSong(song)
                    showingAddMenu = false
                }
            }
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

private struct LiveSetlistToolbarContent<Switcher: View>: ToolbarContent {
    @ViewBuilder let setlistSwitcher: Switcher
    let tempoDisplay: String
    let timeSignatureDisplay: String
    @Bindable var audioEngine: AudioEngineManager
    let isLoaded: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    @Binding var showingSongLibrary: Bool
    @Binding var showingManageOutputs: Bool
    let onEditSong: (Song) -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            setlistSwitcher
        }

        #if os(macOS)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                tempoLabel
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .navigation) {
                timeSignatureLabel
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
                songsButton
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                tempoLabel
            }

            ToolbarItem(placement: .navigation) {
                timeSignatureLabel
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
                songsButton
            }

            ToolbarItem(placement: .automatic) {
                manageOutputsButton
            }
        }
        #else
        ToolbarItem(placement: .navigation) {
            tempoLabel
        }

        ToolbarItem(placement: .navigation) {
            timeSignatureLabel
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
            songsButton
        }

        ToolbarItem(placement: .automatic) {
            manageOutputsButton
        }

        ToolbarItem(placement: .automatic) {
            EditButton()
        }
        #endif
    }

    private var tempoLabel: some View {
        ReadOnlyToolbarLabel(title: tempoDisplay, systemImage: "metronome")
    }

    private var timeSignatureLabel: some View {
        ReadOnlyToolbarLabel(title: timeSignatureDisplay, systemImage: "music.quarternote.3")
    }

    private var transportStopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
    }

    private var transportPlayButton: some View {
        Button(action: audioEngine.isPlaying ? onPause : onPlay) {
            Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
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

private struct ReadOnlyToolbarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
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
