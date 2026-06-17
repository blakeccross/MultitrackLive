import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SongLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Song.createdAt, order: .reverse) private var songs: [Song]

    @State private var showingNewSongAlert = false
    @State private var showingFolderImporter = false
    @State private var newSongName = ""
    @State private var songPendingImport: Song?
    @State private var songPendingRename: Song?
    @State private var renameSongName = ""
    @State private var songPendingDelete: Song?
    @State private var importError: String?
    @State private var createSongError: String?
    @State private var songActionError: String?
    @State private var folderImportSummary: String?

    var body: some View {
        NavigationStack {
            Group {
                if songs.isEmpty {
                    ContentUnavailableView(
                        "No Songs Yet",
                        systemImage: "music.note",
                        description: Text("Create a song or import a folder with multitrack stems and an Ableton file.")
                    )
                } else {
                    List(songs) { song in
                        NavigationLink {
                            SongDetailView(song: song)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.name)
                                    .font(.headline)
                                Text("\(song.tracks.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Rename") {
                                songPendingRename = song
                                renameSongName = song.name
                            }
                            Button("Duplicate") {
                                duplicateSong(song)
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                songPendingDelete = song
                            }
                        }
                    }
                }
            }
            .navigationTitle("Songs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            newSongName = ""
                            showingNewSongAlert = true
                        } label: {
                            Label("New Song", systemImage: "plus")
                        }

                        Button {
                            showingFolderImporter = true
                        } label: {
                            Label("Import from Folder", systemImage: "folder")
                        }
                    } label: {
                        Label("Add Song", systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderImport(result)
            }
            .alert("New Song", isPresented: $showingNewSongAlert) {
                TextField("Song name", text: $newSongName)
                Button("Create") {
                    createSong()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name, then import your stem files or choose a song folder.")
            }
            .alert("Import Complete", isPresented: Binding(
                get: { folderImportSummary != nil },
                set: { if !$0 { folderImportSummary = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(folderImportSummary ?? "")
            }
            .sheet(item: $songPendingImport) { song in
                TrackImportView(song: song) { error in
                    importError = error
                }
            }
            .alert("Import Failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
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
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            do {
                let importResult = try SongFolderImporter.importFromFolder(
                    at: folderURL,
                    context: modelContext
                )
                folderImportSummary = folderImportSummaryText(for: importResult)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func folderImportSummaryText(for result: SongFolderImporter.ImportResult) -> String {
        var lines = ["Created \"\(result.song.name)\" with \(result.trackCount) track\(result.trackCount == 1 ? "" : "s")."]
        if result.sectionCount > 0, let bpm = result.bpm {
            var line = "Imported \(result.sectionCount) sections from Ableton at \(String(format: "%.1f", bpm)) BPM."
            if let timeSignature = result.song.timeSignatureDisplay {
                line += " Time signature: \(timeSignature)."
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func createSong() {
        let trimmed = newSongName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let song = Song(name: trimmed)
        modelContext.insert(song)

        do {
            try modelContext.save()
            songPendingImport = song
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
        modelContext.insert(copy)

        var trackIDMap: [UUID: UUID] = [:]

        do {
            for track in source.sortedTracks {
                let newTrackID = UUID()
                trackIDMap[track.id] = newTrackID

                let destinationPath = try FileStore.copyTrackFile(
                    from: source.id,
                    to: copy.id,
                    relativePath: track.relativeFilePath,
                    newTrackID: newTrackID
                )

                let newTrack = AudioTrack(
                    displayName: track.displayName,
                    relativeFilePath: destinationPath,
                    sortOrder: track.sortOrder
                )
                newTrack.volume = track.volume
                newTrack.pan = track.pan
                newTrack.isMuted = track.isMuted
                newTrack.isSolo = track.isSolo
                newTrack.trimStartSeconds = track.trimStartSeconds
                newTrack.trimEndSeconds = track.trimEndSeconds
                newTrack.excludeFromTranspose = track.excludeFromTranspose
                newTrack.group = track.group
                newTrack.song = copy
            }

            try FileStore.copyArrangementData(
                from: source.id,
                to: copy.id,
                trackIDMap: trackIDMap
            )
            try modelContext.save()
        } catch {
            modelContext.delete(copy)
            FileStore.deleteSongFiles(for: copy.id)
            songActionError = error.localizedDescription
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
            FileStore.deleteSongFiles(for: songID)
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

#Preview {
    SongLibraryView()
        .modelContainer(for: [Song.self, AudioTrack.self], inMemory: true)
}
