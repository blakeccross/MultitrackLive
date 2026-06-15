import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TrackImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let song: Song
    let onError: (String) -> Void

    @State private var showingImporter = true
    @State private var importedCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Import stems for \(song.name)")
                    .font(.headline)

                if importedCount > 0 {
                    Text("\(importedCount) track\(importedCount == 1 ? "" : "s") imported")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select multiple audio files (.wav, .aiff, .mp3, .m4a)")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Choose Files") {
                    showingImporter = true
                }
                .buttonStyle(.borderedProminent)

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
}

#Preview {
    TrackImportView(song: Song(name: "Demo")) { _ in }
        .modelContainer(for: [Song.self, AudioTrack.self], inMemory: true)
}
