import SwiftData
import SwiftUI

struct TrackGroupEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var groups: [TrackGroup]

    @State private var newGroupName = ""
    @State private var nameError: String?

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Rename, add, or remove groups. Tracks assigned to a deleted group become unassigned.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)

                    List {
                        ForEach(groups) { group in
                            TrackGroupNameRow(group: group, onNameError: { nameError = $0 })
                        }
                        .onDelete(perform: deleteGroups)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)

                    HStack(spacing: AppSpacing.xs) {
                        TextField("New group name", text: $newGroupName)
                            .textFieldStyle(.plain)
                            .padding(AppSpacing.sm)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                            .onSubmit(addGroup)

                        AppPrimaryButton(
                            title: "Add Group",
                            isEnabled: !newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            addGroup()
                        }
                    }

                    if let nameError {
                        Text(nameError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(AppSpacing.md)
                .navigationTitle("Track Groups")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .foregroundStyle(AppColors.accent)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }

    private func addGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard TrackGroupStore.isNameAvailable(trimmed, excluding: nil, in: modelContext) else {
            nameError = "A group with that name already exists."
            return
        }

        _ = TrackGroupStore.addGroup(named: trimmed, in: modelContext)
        newGroupName = ""
        nameError = nil
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            TrackGroupStore.delete(groups[index], in: modelContext)
        }
        nameError = nil
    }
}

private struct TrackGroupNameRow: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var group: TrackGroup
    let onNameError: (String?) -> Void

    @State private var draftName: String = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Group name", text: $draftName)
            .textFieldStyle(.plain)
            .foregroundStyle(AppColors.textPrimary)
            .focused($isEditing)
            .onAppear {
                draftName = group.name
            }
            .onChange(of: group.name) { _, newValue in
                if !isEditing {
                    draftName = newValue
                }
            }
            .onSubmit(commitName)
            .onChange(of: isEditing) { _, editing in
                if !editing {
                    commitName()
                }
            }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftName = group.name
            onNameError("Group name cannot be empty.")
            return
        }

        guard TrackGroupStore.isNameAvailable(trimmed, excluding: group.id, in: modelContext) else {
            draftName = group.name
            onNameError("A group with that name already exists.")
            return
        }

        group.name = trimmed
        try? modelContext.save()
        onNameError(nil)
    }
}
