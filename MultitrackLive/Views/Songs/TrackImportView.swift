import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TrackImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let song: Song
    let onError: (String) -> Void

    @State private var showingImporter = true
    @State private var showingFolderImporter = false
    @State private var importedCount = 0
    @State private var importedSectionCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Import stems for \(song.name)")
                    .font(.headline)

                if importedCount > 0 {
                    Text("\(importedCount) track\(importedCount == 1 ? "" : "s") imported")
                        .foregroundStyle(.secondary)
                    if importedSectionCount > 0 {
                        Text("\(importedSectionCount) Ableton section\(importedSectionCount == 1 ? "" : "s") imported")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Select audio files or a folder containing a Multitracks subfolder and an optional Ableton file.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Choose Files") {
                    showingImporter = true
                }
                .buttonStyle(.borderedProminent)

                Button("Choose Folder") {
                    showingFolderImporter = true
                }
                .buttonStyle(.bordered)

                if importedCount > 0 {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Import Tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: FileStore.supportedTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderImport(result)
            }
            .onAppear {
                showingImporter = true
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            onError(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            do {
                let tracks = try FileStore.importTracks(from: urls, into: song)
                for track in tracks {
                    modelContext.insert(track)
                    song.tracks.append(track)
                }
                try modelContext.save()
                importedCount += tracks.count
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            onError(error.localizedDescription)
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            do {
                let importResult = try SongFolderImporter.importIntoExistingSong(
                    at: folderURL,
                    song: song,
                    context: modelContext
                )
                importedCount += importResult.trackCount
                importedSectionCount += importResult.sectionCount
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

#Preview {
    TrackImportView(song: Song(name: "Demo")) { _ in }
        .modelContainer(for: [Song.self, AudioTrack.self], inMemory: true)
}
