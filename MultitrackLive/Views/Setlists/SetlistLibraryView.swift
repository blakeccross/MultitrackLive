import SwiftData
import SwiftUI

struct SetlistLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Setlist.createdAt, order: .reverse) private var setlists: [Setlist]

    @State private var showingNewSetlistAlert = false
    @State private var newSetlistName = ""

    var body: some View {
        NavigationStack {
            Group {
                if setlists.isEmpty {
                    ContentUnavailableView(
                        "No Setlists Yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Create a setlist to arrange songs for live playback.")
                    )
                } else {
                    List(setlists) { setlist in
                        NavigationLink {
                            SetlistDetailView(setlist: setlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(setlist.name)
                                    .font(.headline)
                                Text("\(setlist.entries.count) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Setlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Setlist") {
                        newSetlistName = ""
                        showingNewSetlistAlert = true
                    }
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
        }
    }

    private func createSetlist() {
        let trimmed = newSetlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let setlist = Setlist(name: trimmed)
        modelContext.insert(setlist)
        try? modelContext.save()
    }
}

#Preview {
    SetlistLibraryView()
        .modelContainer(for: [Setlist.self, SetlistEntry.self, Song.self], inMemory: true)
}
