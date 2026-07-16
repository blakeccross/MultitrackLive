import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

private enum SongLibrarySortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case name = "Name"

    var id: String { rawValue }
}

struct SongLibraryPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.createdAt, order: .reverse) private var songs: [Song]

    var onEdit: (Song) -> Void
    var onDismiss: () -> Void
    var onFolderSelected: (URL) -> Void
    var onRequestTrackImport: (Song) -> Void
    var onAddToSetlist: (Song) -> Void

    @State private var searchText = ""
    @State private var sortOrder: SongLibrarySortOrder = .newest
    @State private var showingNewSongAlert = false
    @State private var newSongName = ""
    @State private var songPendingRename: Song?
    @State private var renameSongName = ""
    @State private var songPendingDelete: Song?
    @State private var createSongError: String?
    @State private var songActionError: String?
    @State private var showingProjectImporter = false
    #if !os(macOS)
    @State private var showingFolderImporter = false
    #endif
    @State private var consolidateSummary: String?

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredSongs: [Song] {
        var result = songs

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }

        switch sortOrder {
        case .newest:
            result.sort { $0.createdAt > $1.createdAt }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            searchBar
            songList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.backgroundSecondary)
        .alert("New Song", isPresented: $showingNewSongAlert) {
            TextField("Song name", text: $newSongName)
            Button("Create") {
                createSong()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name, then import your stem files or choose a song folder.")
        }
        .alert("Could Not Create Song", isPresented: Binding(
            get: { createSongError != nil },
            set: { if !$0 { createSongError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createSongError ?? "")
        }
        .alert("Rename Song", isPresented: Binding(
            get: { songPendingRename != nil },
            set: { if !$0 { songPendingRename = nil } }
        )) {
            TextField("Song name", text: $renameSongName)
            Button("Rename") {
                renameSong()
            }
            Button("Cancel", role: .cancel) {
                songPendingRename = nil
            }
        }
        .confirmationDialog(
            "Remove Song",
            isPresented: Binding(
                get: { songPendingDelete != nil },
                set: { if !$0 { songPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let song = songPendingDelete {
                    removeSong(song)
                }
                songPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                songPendingDelete = nil
            }
        } message: {
            if let song = songPendingDelete {
                Text("\"\(song.name)\" and its tracks will be permanently deleted.")
            }
        }
        .alert("Could Not Update Song", isPresented: Binding(
            get: { songActionError != nil },
            set: { if !$0 { songActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(songActionError ?? "")
        }
        .fileImporter(
            isPresented: $showingProjectImporter,
            allowedContentTypes: [ProjectUTType.songProjectType],
            allowsMultipleSelection: false
        ) { result in
            handleOpenProject(result)
        }
        #if !os(macOS)
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        #endif
        .alert("Media Consolidated", isPresented: Binding(
            get: { consolidateSummary != nil },
            set: { if !$0 { consolidateSummary = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(consolidateSummary ?? "")
        }
    }

    private var headerBar: some View {
        ZStack {
            Text("Songs")
                .appLargeTitle()

            HStack {
                AppIconButton(
                    systemImage: "chevron.left",
                    size: 40,
                    accessibilityLabel: "Close songs library"
                ) {
                    onDismiss()
                }

                Spacer()

                addSongMenu
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.xs)
    }

    private var addSongMenu: some View {
        Menu {
            Button {
                newSongName = ""
                showingNewSongAlert = true
            } label: {
                Label("New Song", systemImage: "plus")
            }

            Button {
                presentFolderImporter()
            } label: {
                Label("Import from Folder", systemImage: "folder")
            }

            Button {
                showingProjectImporter = true
            } label: {
                Label("Open Project File…", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus.circle")
                .foregroundStyle(AppColors.accent)
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Add song")
    }

    private var searchBar: some View {
        HStack(spacing: AppSpacing.xs) {
            AppSearchField(text: $searchText)

            if hasActiveSearch {
                Button("Clear") {
                    searchText = ""
                }
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .buttonStyle(.plain)
            }

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SongLibrarySortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(AppColors.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Sort songs")
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.bottom, AppSpacing.xs)
    }

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            AppEmptyState(
                title: "No Songs Yet",
                systemImage: "music.note",
                description: "Create a song or import a folder with multitrack stems and an Ableton file."
            )
            .padding(.top, AppSpacing.sm)
            Spacer(minLength: 0)
        } else if filteredSongs.isEmpty {
            AppEmptyState(
                title: "No Results",
                systemImage: "magnifyingglass",
                description: "No songs match \"\(searchText)\"."
            )
            .padding(.top, AppSpacing.sm)
            Spacer(minLength: 0)
        } else {
            List {
                ForEach(filteredSongs) { song in
                    SongLibraryRow(
                        song: song,
                        onSelect: { onEdit(song) },
                        onAddToSetlist: { onAddToSetlist(song) }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                        .contextMenu {
                            songContextMenu(for: song)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                songPendingDelete = song
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(AppColors.separator)
        }
    }

    @ViewBuilder
    private func songContextMenu(for song: Song) -> some View {
        Button {
            onEdit(song)
        } label: {
            Label("Edit Song", systemImage: "pencil")
        }
        Button("Rename") {
            songPendingRename = song
            renameSongName = song.name
        }
        Button("Duplicate") {
            duplicateSong(song)
        }
        if SongProjectBridge.projectURL(for: song) != nil {
            Button("Consolidate Media…") {
                consolidateMedia(for: song)
            }
        }
        Divider()
        Button("Remove", role: .destructive) {
            songPendingDelete = song
        }
    }

    private func createSong() {
        let trimmed = newSongName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let song = Song(name: trimmed)
        modelContext.insert(song)

        do {
            try modelContext.save()
            _ = try SongProjectBridge.ensureProjectFile(for: song, context: modelContext)
            onRequestTrackImport(song)
        } catch {
            modelContext.delete(song)
            createSongError = error.localizedDescription
        }
    }

    private func renameSong() {
        let trimmed = renameSongName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let song = songPendingRename, !trimmed.isEmpty else {
            songPendingRename = nil
            return
        }

        song.name = trimmed
        do {
            try modelContext.save()
            try SongProjectBridge.syncProjectFile(for: song, context: modelContext)
            songPendingRename = nil
        } catch {
            songActionError = error.localizedDescription
        }
    }

    private func duplicateSong(_ source: Song) {
        let copy = Song(name: duplicateName(for: source.name))
        copy.bpm = source.bpm
        copy.timeSignatureNumerator = source.timeSignatureNumerator
        copy.timeSignatureDenominator = source.timeSignatureDenominator
        copy.transposeSemitones = source.transposeSemitones
        copy.transposeHighQuality = source.transposeHighQuality
        copy.dynamicCuesEnabled = source.dynamicCuesEnabled
        modelContext.insert(copy)

        var trackIDMap: [UUID: UUID] = [:]

        do {
            for track in source.sortedTracks {
                let newTrackID = UUID()
                trackIDMap[track.id] = newTrackID

                let newTrack = AudioTrack(
                    displayName: track.displayName,
                    relativeFilePath: track.relativeFilePath,
                    sortOrder: track.sortOrder
                )
                newTrack.id = newTrackID
                newTrack.volume = track.volume
                newTrack.isMuted = track.isMuted
                newTrack.isSolo = track.isSolo
                newTrack.trimStartSeconds = track.trimStartSeconds
                newTrack.trimEndSeconds = track.trimEndSeconds
                newTrack.excludeFromTranspose = track.excludeFromTranspose
                newTrack.mediaPath = track.mediaPath
                newTrack.mediaPathStyle = track.mediaPathStyle
                newTrack.mediaBookmarkData = track.mediaBookmarkData
                newTrack.group = track.group
                newTrack.song = copy
                modelContext.insert(newTrack)
                copy.tracks.append(newTrack)
            }

            let sourceState = try SongProjectBridge.loadProjectState(for: source)
            var arrangement = sourceState.arrangement
            arrangement.clipTrims = arrangement.clipTrims.map { trim in
                ArrangementClipTrim(
                    slotID: trim.slotID,
                    trackID: trackIDMap[trim.trackID] ?? trim.trackID,
                    leadingTrim: trim.leadingTrim,
                    trailingTrim: trim.trailingTrim
                )
            }
            arrangement.removedClips = arrangement.removedClips.map { removed in
                ArrangementRemovedClip(
                    slotID: removed.slotID,
                    trackID: trackIDMap[removed.trackID] ?? removed.trackID
                )
            }
            arrangement.clipGaps = arrangement.clipGaps.map { gap in
                ArrangementClipGap(
                    slotID: gap.slotID,
                    trackID: trackIDMap[gap.trackID] ?? gap.trackID,
                    sourceStartSeconds: gap.sourceStartSeconds,
                    sourceEndSeconds: gap.sourceEndSeconds
                )
            }
            arrangement.clipRegions = arrangement.clipRegions.map { region in
                ClipRegion(
                    id: region.id,
                    slotID: region.slotID,
                    trackID: trackIDMap[region.trackID] ?? region.trackID,
                    markerID: region.markerID,
                    sourceStartSeconds: region.sourceStartSeconds,
                    sourceEndSeconds: region.sourceEndSeconds,
                    timelineStartSeconds: region.timelineStartSeconds,
                    timelineEndSeconds: region.timelineEndSeconds
                )
            }
            let midiEvents = sourceState.midiEvents.map { event in
                MIDIEvent(
                    id: event.id,
                    trackID: trackIDMap[event.trackID] ?? event.trackID,
                    timelineSeconds: event.timelineSeconds,
                    commandID: event.commandID,
                    label: event.label
                )
            }

            try modelContext.save()
            try SongProjectBridge.syncProjectFile(
                for: copy,
                context: modelContext,
                markers: sourceState.markers,
                arrangement: arrangement,
                tempoChanges: sourceState.tempoChanges,
                timeSignatureChanges: sourceState.timeSignatureChanges,
                midiEvents: midiEvents
            )
        } catch {
            modelContext.delete(copy)
            FileStore.deleteProjectFile(for: copy)
            songActionError = error.localizedDescription
        }
    }

    private func consolidateMedia(for song: Song) {
        do {
            let stemsDirectory = try MediaConsolidator.consolidate(for: song, context: modelContext)
            consolidateSummary = "Copied media to \(stemsDirectory.path)."
        } catch {
            songActionError = error.localizedDescription
        }
    }

    private func presentFolderImporter() {
        #if os(macOS)
        // SwiftUI `.fileImporter` often fails to present from a Menu. Use NSOpenPanel after
        // the menu finishes dismissing so Finder reliably appears.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.prompt = "Import"
            panel.message = "Choose a song folder with stems (and an optional Ableton Live Set)."
            guard panel.runModal() == .OK, let folderURL = panel.url else { return }
            onFolderSelected(folderURL)
        }
        #else
        showingFolderImporter = true
        #endif
    }

    private func handleOpenProject(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            songActionError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try SongProjectBridge.importProject(from: url, into: modelContext)
            } catch {
                songActionError = error.localizedDescription
            }
        }
    }

    #if !os(macOS)
    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            songActionError = error.localizedDescription
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            onFolderSelected(folderURL)
        }
    }
    #endif

    private func removeSong(_ song: Song) {
        let songID = song.id

        if let entries = try? modelContext.fetch(FetchDescriptor<SetlistEntry>()) {
            for entry in entries where entry.song?.id == songID {
                entry.setlist?.entries.removeAll { $0 === entry }
                modelContext.delete(entry)
            }
        }

        modelContext.delete(song)

        do {
            try modelContext.save()
            FileStore.deleteProjectFile(for: song)
        } catch {
            songActionError = error.localizedDescription
        }
    }

    private func duplicateName(for baseName: String) -> String {
        let existingNames = Set(songs.map(\.name))
        let firstCandidate = "\(baseName) Copy"
        if !existingNames.contains(firstCandidate) {
            return firstCandidate
        }

        var index = 2
        while existingNames.contains("\(baseName) Copy \(index)") {
            index += 1
        }
        return "\(baseName) Copy \(index)"
    }
}

private struct SongLibraryRow: View {
    let song: Song
    let onSelect: () -> Void
    let onAddToSetlist: () -> Void

    private var subtitle: String {
        let trackText = song.tracks.isEmpty ? "No tracks" : "\(song.tracks.count) tracks"
        if let bpm = song.bpm {
            return "\(Int(bpm.rounded())) bpm — \(trackText)"
        }
        return trackText
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(AppColors.surface)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }

            Spacer(minLength: 0)

            AppIconButton(
                systemImage: "plus.circle",
                size: 36,
                accessibilityLabel: "Add to setlist"
            ) {
                onAddToSetlist()
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 0.5)
        }
    }
}

#Preview {
    SongLibraryPanel(
        onEdit: { _ in },
        onDismiss: {},
        onFolderSelected: { _ in },
        onRequestTrackImport: { _ in },
        onAddToSetlist: { _ in }
    )
        .frame(width: 300, height: 600)
        .modelContainer(for: [Song.self, AudioTrack.self], inMemory: true)
}
