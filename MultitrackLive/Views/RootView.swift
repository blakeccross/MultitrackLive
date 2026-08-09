import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var remoteClient = RemoteSessionClientService.shared

    var body: some View {
        VStack(spacing: 0) {
            if remoteClient.isConnected {
                remoteConnectedStatusBanner
            }

            NavigationStack {
                rootContent
            }
        }
        .appBackground(.primary)
        .appLockToolbarDisplayMode()
        .onAppear {
            // Ensure host session bindings exist before any remote client connects.
            _ = RemoteHostSessionController.shared
            TrackGroupStore.ensureDefaults(in: modelContext)
            OutputRoutingStore.ensureConfig(in: modelContext)
            TimecodeSettingsStore.ensureConfig(in: modelContext)
            SongProjectBridge.restoreShowsFromDisk(in: modelContext)
            RemoteHostSessionController.shared.syncAdvertising()
        }
    }

    private var remoteConnectedStatusBanner: some View {
        let hostName = remoteClient.hostDisplayName
            ?? remoteClient.snapshot?.hostDisplayName
            ?? "Host"
        return Text("Connected to: \(hostName)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, AppSpacing.sm)
            .background(AppColors.accent)
            // Fill the status-bar / Dynamic Island area without covering the nav toolbar.
            .background(alignment: .top) {
                AppColors.accent
                    .ignoresSafeArea(edges: .top)
            }
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var rootContent: some View {
        if remoteClient.isConnected {
            if remoteClient.snapshot != nil {
                RemoteLivePlaybackView()
            } else {
                remoteSessionLoadingView
            }
        } else if case .failed(let message) = remoteClient.phase {
            remoteSessionErrorView(message: message)
        } else {
            LivePlaybackView()
        }
    }

    private var remoteSessionLoadingView: some View {
        VStack(spacing: AppSpacing.md) {
            ProgressView()
            Text("Loading setlist from host…")
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
            Text("This should only take a few seconds.")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            if let host = remoteClient.hostDisplayName {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            Button("Cancel") {
                remoteClient.disconnect()
                remoteClient.startBrowsing()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Remote Session")
    }

    private func remoteSessionErrorView(message: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Remote Session Failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("OK") {
                remoteClient.clearFailure()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Remote Session")
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Song.self, AudioTrack.self, TrackGroup.self, OutputRoutingConfig.self, GroupOutputRoute.self, TimecodeSettings.self, Setlist.self, SetlistEntry.self], inMemory: true)
}
