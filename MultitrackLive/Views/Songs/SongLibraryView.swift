import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SongLibraryPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.createdAt, order: .reverse) private var songs: [Song]

    var onEdit: (Song) -> Void
    var onDismiss: () -> Void
    var onRequestFolderImport: () -> Void
    var onRequestTrackImport: (Song) -> Void

    @State private var searchText = ""
    @State private var showingNewSongAlert = false
    @State private var showingNewClickTrackSheet = false
    @State private var newSongName = ""
    @State private var newClickTrackBPM: Double = TempoChange.defaultBPM
    @State private var newClickTrackSubdivision: ClickTrackSubdivision = .quarter
    @State private var newClickTrackNumerator: Int = TimeSignatureChange.defaultNumerator
    @State private var newClickTrackDenominator: Int = TimeSignatureChange.defaultDenominator
    @State private var songPendingRename: Song?
    @State private var renameSongName = ""
    @State private var songPendingDelete: Song?
    @State private var createSongError: String?
    @State private var songActionError: String?
    @State private var showingProjectImporter = false
    @State private var consolidateSummary: String?

    private var filteredSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }
        return songs.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Songs")
                    .font(.headline)
                Spacer()
                Menu {
                    Button {
                        newSongName = ""
                        showingNewSongAlert = true
                    } label: {
                        Label("New Song", systemImage: "plus")
                    }

                    Button {
                        resetNewClickTrackForm()
                        showingNewClickTrackSheet = true
                    } label: {
                        Label("New Click Track", systemImage: "cursorarrow.click")
                    }

                    Button {
                        onRequestFolderImport()
                    } label: {
                        Label("Import from Folder", systemImage: "folder")
                    }

                    Button {
                        showingProjectImporter = true
                    } label: {
                        Label("Open Project File…", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Add song")

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close songs menu")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            TextField("Search songs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Group {
                if songs.isEmpty {
                    ContentUnavailableView(
                        "No Songs Yet",
                        systemImage: "music.note",
                        description: Text("Create a song or import a folder with multitrack stems and an Ableton file.")
                    )
                    .padding(.top, 12)

                    Spacer(minLength: 0)
                } else if filteredSongs.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 12)

                    Spacer(minLength: 0)
                } else {
                    List(filteredSongs) { song in
                        SongLibraryRow(song: song)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !song.isClickOnly else { return }
                                onEdit(song)
                            }
                            .contextMenu {
                                if !song.isClickOnly {
                                    Button {
                                        onEdit(song)
                                    } label: {
                                        Label("Edit Song", systemImage: "pencil")
                                    }
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
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .alert("New Song", isPresented: $showingNewSongAlert) {
            TextField("Song name", text: $newSongName)
            Button("Create") {
                createSong()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name, then import your stem files or choose a song folder.")
        }
        .sheet(isPresented: $showingNewClickTrackSheet) {
            NewClickTrackSheet(
                name: $newSongName,
                bpm: $newClickTrackBPM,
                subdivision: $newClickTrackSubdivision,
                numerator: $newClickTrackNumerator,
                denominator: $newClickTrackDenominator,
                onCreate: createClickTrack,
                onCancel: {
                    showingNewClickTrackSheet = false
                }
            )
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
        .alert("Media Consolidated", isPresented: Binding(
            get: { consolidateSummary != nil },
            set: { if !$0 { consolidateSummary = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(consolidateSummary ?? "")
        }
    }

    private func resetNewClickTrackForm() {
        newSongName = ""
        newClickTrackBPM = TempoChange.defaultBPM
        newClickTrackSubdivision = .quarter
        newClickTrackNumerator = TimeSignatureChange.defaultNumerator
        newClickTrackDenominator = TimeSignatureChange.defaultDenominator
    }

    private func createClickTrack() {
        let trimmed = newSongName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard TempoChange.validBPMRange.contains(newClickTrackBPM) else { return }
        guard (1...32).contains(newClickTrackNumerator),
              TimeSignatureChange.validDenominators.contains(newClickTrackDenominator) else { return }

        let song = Song(name: trimmed)
        song.isClickOnly = true
        song.clickTrackEnabled = true
        song.bpm = newClickTrackBPM
        song.timeSignatureNumerator = newClickTrackNumerator
        song.timeSignatureDenominator = newClickTrackDenominator
        song.clickTrackSubdivision = newClickTrackSubdivision.rawValue
        modelContext.insert(song)

        do {
            try modelContext.save()
            try SongProjectBridge.syncProjectFile(for: song, context: modelContext)
            showingNewClickTrackSheet = false
            resetNewClickTrackForm()
        } catch {
            modelContext.delete(song)
            FileStore.deleteProjectFile(for: song)
            createSongError = error.localizedDescription
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
        copy.isClickOnly = source.isClickOnly
        copy.clickTrackEnabled = source.clickTrackEnabled
        copy.clickTrackVolume = source.clickTrackVolume
        copy.clickTrackSubdivision = source.clickTrackSubdivision
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
                newTrack.pan = track.pan
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

private struct NewClickTrackSheet: View {
    @Binding var name: String
    @Binding var bpm: Double
    @Binding var subdivision: ClickTrackSubdivision
    @Binding var numerator: Int
    @Binding var denominator: Int

    let onCreate: () -> Void
    let onCancel: () -> Void

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && TempoChange.validBPMRange.contains(bpm)
            && (1...32).contains(numerator)
            && TimeSignatureChange.validDenominators.contains(denominator)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name:", text: $name)

                LabeledContent("Tempo:") {
                    Stepper(value: $bpm, in: TempoChange.validBPMRange, step: 1) {
                        Text("\(Int(bpm.rounded())) BPM")
                            .monospacedDigit()
                    }
                }

                LabeledContent("Meter:") {
                    HStack(spacing: 8) {
                        Picker("Beats:", selection: $numerator) {
                            ForEach(1...32, id: \.self) { value in
                                Text("\(value)").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)

                        Text("/")
                            .foregroundStyle(.secondary)

                        Picker("Beat value:", selection: $denominator) {
                            ForEach(TimeSignatureChange.validDenominators.filter { $0 != 1 }, id: \.self) { value in
                                Text("\(value)").tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }
                }

                Picker("Subdivision:", selection: $subdivision) {
                    ForEach(ClickTrackSubdivision.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Click Track")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .disabled(!canCreate)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420)
        #endif
    }
}

private struct SongLibraryRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(song.isClickOnly ? song.clickTrackSummary : "\(song.tracks.count) tracks")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    SongLibraryPanel(
        onEdit: { _ in },
        onDismiss: {},
        onRequestFolderImport: {},
        onRequestTrackImport: { _ in }
    )
        .frame(width: 280)
        .modelContainer(for: [Song.self, AudioTrack.self], inMemory: true)
}
