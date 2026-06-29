import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            LivePlaybackView()
        }
        .appBackground(.primary)
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
