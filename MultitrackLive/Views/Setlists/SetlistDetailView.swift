import SwiftData
import SwiftUI

struct SetlistDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let setlist: Setlist

    @State private var viewModel = SetlistViewModel()
    @State private var showingSongPicker = false
    @State private var showingLivePlayback = false

    var body: some View {
        VStack(spacing: 0) {
            if setlist.sortedEntries.isEmpty {
                ContentUnavailableView(
                    "No Songs in Setlist",
                    systemImage: "music.note.list",
                    description: Text("Add songs in the order you want to perform them.")
                )
            } else {
                List {
                    ForEach(setlist.sortedEntries) { entry in
                        if let song = entry.song {
                            HStack {
                                Text(song.name)
                                Spacer()
                                Text("\(song.tracks.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        viewModel.moveEntries(in: setlist, from: source, to: destination, context: modelContext)
                    }
                    .onDelete { indexSet in
                        let entries = setlist.sortedEntries
                        for index in indexSet {
                            viewModel.removeEntry(entries[index], from: setlist, context: modelContext)
                        }
                    }
                }
            }

            HStack {
                Button("Add Song") {
                    showingSongPicker = true
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Play Setlist") {
                    showingLivePlayback = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(setlist.sortedEntries.isEmpty)
            }
            .padding()
        }
        .navigationTitle(setlist.name)
        #if os(iOS)
        .toolbar {
            EditButton()
        }
        #endif
        .sheet(isPresented: $showingSongPicker) {
            SongPickerView { song in
                viewModel.addSong(song, to: setlist, context: modelContext)
            }
        }
        .navigationDestination(isPresented: $showingLivePlayback) {
            LivePlaybackView(setlist: setlist)
        }
    }
}

private struct SongPickerView: View {
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
        SetlistDetailView(setlist: Setlist(name: "Sunday"))
    }
    .modelContainer(for: [Setlist.self, SetlistEntry.self, Song.self], inMemory: true)
}
