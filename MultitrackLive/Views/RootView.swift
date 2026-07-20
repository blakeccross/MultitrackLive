import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            LivePlaybackView()
        }
        .appBackground(.primary)
        .appLockToolbarDisplayMode()
        .onAppear {
            TrackGroupStore.ensureDefaults(in: modelContext)
            OutputRoutingStore.ensureConfig(in: modelContext)
            SongProjectBridge.restoreShowsFromDisk(in: modelContext)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Song.self, AudioTrack.self, TrackGroup.self, OutputRoutingConfig.self, GroupOutputRoute.self, Setlist.self, SetlistEntry.self], inMemory: true)
}
