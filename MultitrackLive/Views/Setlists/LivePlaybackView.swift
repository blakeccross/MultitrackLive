import SwiftData
import SwiftUI

struct LivePlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let setlist: Setlist

    @State private var coordinator = PlaybackCoordinator()
    @State private var viewModel = SetlistViewModel()
    @Bindable private var audioEngine = AudioEngineManager.shared
    @State private var cuedSectionID: UUID?
    @State private var cueFireTime: TimeInterval?
    @State private var cueFlashPhase = false
    @State private var activeLoopSectionID: UUID?
    @State private var suppressedLoopSectionIDs: Set<UUID> = []
    @State private var showingSongPicker = false
    @State private var showingManageOutputs = false

    var body: some View {
        VStack(spacing: 0) {
            currentSongSection
                .padding()

            Divider()

            setlistSection
        }
        .navigationTitle(setlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
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
                Button("Add Song") {
                    showingSongPicker = true
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
        .sheet(isPresented: $showingSongPicker) {
            SetlistSongPickerView { song in
                viewModel.addSong(song, to: setlist, context: modelContext)
                coordinator.syncSetlist(setlist)
            }
        }
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
            coordinator.routingProvider = {
                let channelCount = AudioOutputDeviceService.channelCount(
                    for: OutputRoutingStore.config(in: modelContext).selectedDeviceUID
                )
                return OutputRoutingStore.snapshot(in: modelContext, channelCount: channelCount)
            }
            coordinator.configure(setlist: setlist)
        }
        .onDisappear {
            clearMarkerCue()
            activeLoopSectionID = nil
            suppressedLoopSectionIDs.removeAll()
            coordinator.stop()
        }
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
                    playbackDuration: audioEngine.duration,
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

    private var setlistSection: some View {
        Group {
            if setlist.sortedEntries.isEmpty {
                ContentUnavailableView(
                    "No Songs in Setlist",
                    systemImage: "music.note.list",
                    description: Text("Add songs in the order you want to perform them.")
                )
            } else {
                List {
                    Section("Setlist") {
                        ForEach(Array(setlist.sortedEntries.enumerated()), id: \.element.id) { index, entry in
                            if let song = entry.song {
                                SetlistPlaybackRow(
                                    song: song,
                                    index: index,
                                    currentIndex: coordinator.currentIndex,
                                    isPlaying: audioEngine.isPlaying,
                                    transition: index < setlist.sortedEntries.count - 1 ? entry.transition : nil,
                                    onTransitionChange: { transition in
                                        viewModel.setTransition(transition, for: entry, context: modelContext)
                                        coordinator.updateTransitions(from: setlist)
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let songIndex = coordinator.songs.firstIndex(where: { $0.id == song.id }) {
                                        coordinator.goToSong(at: songIndex, autoPlay: audioEngine.isPlaying)
                                    }
                                }
                            }
                        }
                        .onMove { source, destination in
                            viewModel.moveEntries(in: setlist, from: source, to: destination, context: modelContext)
                            coordinator.syncSetlist(setlist)
                        }
                        .onDelete { indexSet in
                            let entries = setlist.sortedEntries
                            for index in indexSet {
                                viewModel.removeEntry(entries[index], from: setlist, context: modelContext)
                            }
                            coordinator.syncSetlist(setlist)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
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
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.08) : nil)
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

private struct SetlistSongPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Song.createdAt, order: .reverse) private var songs: [Song]

    let onSelect: (Song) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if songs.isEmpty {
                    ContentUnavailableView(
                        "No Songs Available",
                        systemImage: "music.note",
                        description: Text("Create songs in the Songs tab before adding them to a setlist.")
                    )
                } else {
                    List(songs) { song in
                        Button {
                            onSelect(song)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.name)
                                    .font(.headline)
                                Text("\(song.tracks.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Song")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    NavigationStack {
        LivePlaybackView(setlist: Setlist(name: "Sunday"))
    }
    .modelContainer(for: [Setlist.self, SetlistEntry.self, Song.self], inMemory: true)
}
