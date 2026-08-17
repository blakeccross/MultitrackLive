import SwiftUI

struct InputMappingSettingsView: View {
    @Environment(InputMappingController.self) private var mapping
    @Bindable private var store = InputMappingStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                transportSection
                songsSection
                helpSection
            }
            .padding(AppSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundSecondary)
        .onDisappear {
            if mapping.endsSessionAfterAssign {
                mapping.endMapping()
            }
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Transport")

            VStack(spacing: 0) {
                ForEach(Array(MappableLiveAction.transportActions.enumerated()), id: \.element.id) { index, action in
                    mappingRow(for: action)
                    if index < MappableLiveAction.transportActions.count - 1 {
                        Divider()
                            .background(AppColors.separator)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Songs")

            let songs = store.songMappings
            VStack(alignment: .leading, spacing: 0) {
                if songs.isEmpty {
                    Text("No song mappings yet. Use Key Mapping or MIDI Mapping on the live setlist, then tap a song.")
                        .font(.callout)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(AppSpacing.sm)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, item in
                        mappingRow(for: item.action)
                        if index < songs.count - 1 {
                            Divider()
                                .background(AppColors.separator)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    private var helpSection: some View {
        Text("Mapped keys and MIDI notes trigger the same actions as tapping Stop, Play, Fade, Loop, or a setlist song. Escape cancels mapping.")
            .font(.callout)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mappingRow(for action: MappableLiveAction) -> some View {
        let record = store.mapping(for: action)
        let isLearningKey = mapping.session == .keyMapping && mapping.pendingAction == action
        let isLearningMIDI = mapping.session == .midiMapping && mapping.pendingAction == action

        return HStack(alignment: .center, spacing: AppSpacing.sm) {
            Image(systemName: action.systemImage)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 22)

            Text(action.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            bindingChip(
                title: isLearningKey ? "Press key…" : (record?.key?.displayName ?? "Key"),
                isSet: record?.key != nil,
                isLearning: isLearningKey
            ) {
                mapping.startSettingsLearn(action: action, session: .keyMapping)
            }
            .contextMenu {
                if record?.key != nil {
                    Button("Clear Key", role: .destructive) {
                        store.clearKey(for: action)
                    }
                }
            }

            bindingChip(
                title: isLearningMIDI ? "Send MIDI…" : (record?.midi?.displayName ?? "MIDI"),
                isSet: record?.midi != nil,
                isLearning: isLearningMIDI
            ) {
                mapping.startSettingsLearn(action: action, session: .midiMapping)
            }
            .contextMenu {
                if record?.midi != nil {
                    Button("Clear MIDI", role: .destructive) {
                        store.clearMIDI(for: action)
                    }
                }
            }
        }
        .padding(.vertical, AppSpacing.sm)
    }

    private func bindingChip(
        title: String,
        isSet: Bool,
        isLearning: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .foregroundStyle(isLearning || isSet ? AppColors.textPrimary : AppColors.textSecondary)
                .background(
                    isLearning ? AppColors.accent : AppColors.backgroundSecondary,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isLearning ? AppColors.accent : AppColors.separator,
                            lineWidth: isLearning ? 1.5 : 0.5
                        )
                }
        }
        .buttonStyle(.plain)
        .help(isLearning ? title : "Click to assign")
    }
}