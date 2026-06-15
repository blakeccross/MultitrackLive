import SwiftData
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case songs
    case setlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: return "Songs"
        case .setlists: return "Setlists"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note.list"
        case .setlists: return "list.bullet.rectangle"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selection: AppSection? = .songs

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Multitrack Live")
        } detail: {
            switch selection {
            case .songs:
                SongLibraryView()
            case .setlists:
                SetlistLibraryView()
            case .none:
                ContentUnavailableView("Choose a Section", systemImage: "sidebar.left")
            }
        }
        .onAppear {
            TrackGroupStore.ensureDefaults(in: modelContext)
            OutputRoutingStore.ensureConfig(in: modelContext)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Song.self, AudioTrack.self, TrackGroup.self, OutputRoutingConfig.self, GroupOutputRoute.self, Setlist.self, SetlistEntry.self], inMemory: true)
}
