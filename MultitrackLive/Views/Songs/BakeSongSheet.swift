import SwiftData
import SwiftUI

struct BakeSongSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let song: Song
    let onFinished: () -> Void

    @State private var phase = "Preparing…"
    @State private var completedGroups = 0
    @State private var totalGroups = 1
    @State private var errorMessage: String?
    @State private var bakeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Baking \(song.name)")
                .font(.headline)
                .multilineTextAlignment(.center)

            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)

                Button("Close") {
                    dismiss()
                    onFinished()
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView(value: progressValue, total: 1)
                    .progressViewStyle(.linear)

                Text(phase)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)

                if totalGroups > 0 {
                    Text("\(completedGroups) of \(totalGroups) groups")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
        .padding(AppSpacing.xl)
        .frame(minWidth: 320)
        .onAppear(perform: startBake)
        .onDisappear {
            bakeTask?.cancel()
        }
    }

    private var progressValue: Double {
        guard totalGroups > 0 else { return 0 }
        return Double(completedGroups) / Double(totalGroups)
    }

    private func startBake() {
        bakeTask = Task {
            do {
                _ = try await SongGroupBaker.bake(song: song, context: modelContext) { progress in
                    Task { @MainActor in
                        phase = progress.phase
                        completedGroups = progress.completedGroups
                        totalGroups = max(1, progress.totalGroups)
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    dismiss()
                    onFinished()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
