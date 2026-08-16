import SwiftData
import SwiftUI

struct ChangeKeyDialog: View {
    private enum Step {
        case semitones
        case tracks
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var song: Song
    let viewModel: SongEditorViewModel
    let captureSnapshot: () -> SongEditSnapshot
    let registerUndo: (_ actionName: String, _ before: SongEditSnapshot, _ after: SongEditSnapshot) -> Void

    @State private var step: Step = .semitones
    @State private var semitones: Int = 0
    @State private var transposeTrackIDs: Set<UUID> = []
    @State private var useHighQuality = false
    @State private var isApplying = false
    @State private var applyError: String?

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                Group {
                    switch step {
                    case .semitones:
                        semitoneStep
                    case .tracks:
                        trackSelectionStep
                    }
                }
                .navigationTitle("Change Key")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                        .foregroundStyle(AppColors.textSecondary)
                        .disabled(isApplying)
                    }
                }
                .frame(minWidth: 360, minHeight: step == .semitones ? 220 : 380)
                .padding(AppSpacing.lg)
                .onAppear(perform: resetFromSong)
                .alert("Pitch Shift Failed", isPresented: Binding(
                    get: { applyError != nil },
                    set: { if !$0 { applyError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(applyError ?? "")
                }
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    private func resetFromSong() {
        semitones = song.transposeSemitones
        useHighQuality = song.transposeHighQuality
        transposeTrackIDs = Set(
            song.sortedTracks.filter { !$0.excludeFromTranspose }.map(\.id)
        )
        step = .semitones
    }

    private var semitoneStep: some View {
        VStack(spacing: AppSpacing.xl) {
            Text("Transpose by semitones")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: AppSpacing.lg) {
                AppIconButton(
                    systemImage: "minus.circle",
                    size: 48,
                    isEnabled: semitones > -5
                ) {
                    semitones = max(-5, semitones - 1)
                }

                Text(semitoneLabel)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .frame(minWidth: 140)

                AppIconButton(
                    systemImage: "plus.circle",
                    size: 48,
                    isEnabled: semitones < 5
                ) {
                    semitones = min(5, semitones + 1)
                }
            }

            Text("Range: -5 to +5 semitones")
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)

            Spacer(minLength: 0)

            AppPrimaryButton(title: "Next") {
                step = .tracks
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var trackSelectionStep: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Select tracks to transpose \(semitoneLabel.lowercased()).")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            if song.sortedTracks.isEmpty {
                AppEmptyState(
                    title: "No Tracks",
                    systemImage: "waveform",
                    description: "Import stems before changing key."
                )
            } else {
                List {
                    ForEach(song.sortedTracks) { track in
                        Toggle(isOn: transposeBinding(for: track.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayName)
                                    .foregroundStyle(AppColors.textPrimary)
                                if let groupName = track.group?.name {
                                    Text(groupName)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textTertiary)
                                }
                            }
                        }
                        .tint(AppColors.accent)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Toggle(isOn: $useHighQuality) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High quality (slower)")
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Uses Rubber Band offline processing. Unchecked applies transpose instantly during playback.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .tint(AppColors.accent)
            .disabled(isApplying)

            HStack(spacing: AppSpacing.sm) {
                AppSecondaryButton(title: "Back", isEnabled: !isApplying) {
                    step = .semitones
                }

                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.accent)
                } else {
                    AppPrimaryButton(
                        title: "Apply",
                        isEnabled: !song.sortedTracks.isEmpty
                    ) {
                        applyChanges()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var semitoneLabel: String {
        switch semitones {
        case 0:
            return "Original"
        case 1:
            return "+1 semitone"
        case -1:
            return "-1 semitone"
        case let value where value > 0:
            return "+\(value) semitones"
        default:
            return "\(semitones) semitones"
        }
    }

    private func transposeBinding(for trackID: UUID) -> Binding<Bool> {
        Binding(
            get: { transposeTrackIDs.contains(trackID) },
            set: { isSelected in
                if isSelected {
                    transposeTrackIDs.insert(trackID)
                } else {
                    transposeTrackIDs.remove(trackID)
                }
            }
        )
    }

    private func applyChanges() {
        let before = captureSnapshot()
        song.transposeSemitones = semitones
        for track in song.sortedTracks {
            track.excludeFromTranspose = !transposeTrackIDs.contains(track.id)
        }

        let wasHighQuality = song.transposeHighQuality
        let needsReload = useHighQuality || wasHighQuality

        if needsReload {
            isApplying = true
            Task {
                await viewModel.applyKeyChange(context: modelContext, highQuality: useHighQuality)
                isApplying = false

                if let loadError = viewModel.loadError {
                    applyError = loadError
                } else {
                    let after = captureSnapshot()
                    registerUndo("Change Key", before, after)
                    dismiss()
                }
            }
        } else {
            Task {
                await viewModel.applyKeyChange(context: modelContext, highQuality: false)
                let after = captureSnapshot()
                registerUndo("Change Key", before, after)
                dismiss()
            }
        }
    }
}
