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

    @State private var step: Step = .semitones
    @State private var semitones: Int = 0
    @State private var transposeTrackIDs: Set<UUID> = []
    @State private var useHighQuality = false
    @State private var isApplying = false
    @State private var applyError: String?

    var body: some View {
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
                    .disabled(isApplying)
                }
            }
            .frame(minWidth: 360, minHeight: step == .semitones ? 220 : 380)
            .padding()
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
        VStack(spacing: 24) {
            Text("Transpose by semitones")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Button {
                    semitones = max(-5, semitones - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(semitones <= -5)

                Text(semitoneLabel)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 140)

                Button {
                    semitones = min(5, semitones + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(semitones >= 5)
            }

            Text("Range: -5 to +5 semitones")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Next") {
                step = .tracks
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    private var trackSelectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select tracks to transpose \(semitoneLabel.lowercased()).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if song.sortedTracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "waveform",
                    description: Text("Import stems before changing key.")
                )
            } else {
                List {
                    ForEach(song.sortedTracks) { track in
                        Toggle(isOn: transposeBinding(for: track.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.displayName)
                                if let groupName = track.group?.name {
                                    Text(groupName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Toggle(isOn: $useHighQuality) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High quality (slower)")
                    Text("Uses Rubber Band offline processing. Unchecked applies transpose instantly during playback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isApplying)

            HStack(spacing: 12) {
                Button("Back") {
                    step = .semitones
                }
                .buttonStyle(.bordered)
                .disabled(isApplying)

                Button {
                    applyChanges()
                } label: {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(song.sortedTracks.isEmpty || isApplying)
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
                    dismiss()
                }
            }
        } else {
            Task {
                await viewModel.applyKeyChange(context: modelContext, highQuality: false)
                dismiss()
            }
        }
    }
}
