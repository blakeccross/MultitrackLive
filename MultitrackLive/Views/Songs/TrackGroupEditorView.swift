import SwiftData
import SwiftUI

struct TrackGroupEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\TrackGroup.sortOrder), SortDescriptor(\TrackGroup.name)])
    private var groups: [TrackGroup]

    @State private var newGroupName = ""
    @State private var nameError: String?
    @State private var expandedGroupID: UUID?

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Manage group names, colors, and track-name keywords used for auto-assign. Tracks on a deleted group become unassigned.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)

                    List {
                        ForEach(groups) { group in
                            TrackGroupEditorRow(
                                group: group,
                                isExpanded: expandedGroupID == group.id,
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        expandedGroupID = expandedGroupID == group.id ? nil : group.id
                                    }
                                },
                                onNameError: { nameError = $0 }
                            )
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
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func addGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard TrackGroupStore.isNameAvailable(trimmed, excluding: nil, in: modelContext) else {
            nameError = "A group with that name already exists."
            return
        }

        if let group = TrackGroupStore.addGroup(named: trimmed, in: modelContext) {
            expandedGroupID = group.id
        }
        newGroupName = ""
        nameError = nil
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            let group = groups[index]
            if expandedGroupID == group.id {
                expandedGroupID = nil
            }
            TrackGroupStore.delete(group, in: modelContext)
        }
        nameError = nil
    }
}

private struct TrackGroupEditorRow: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var group: TrackGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onNameError: (String?) -> Void

    @State private var draftName: String = ""
    @State private var draftKeywords: String = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case keywords
    }

    private var bodyColor: Color {
        TrackGroupPalette.colors(for: group).body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bodyColor)
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(AppColors.separator.opacity(0.6), lineWidth: 1)
                    )

                TextField("Group name", text: $draftName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(AppColors.textPrimary)
                    .focused($focusedField, equals: .name)
                    .onSubmit(commitName)

                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                colorPicker

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("Track name keywords")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)

                    Text("Comma-separated names that auto-assign tracks to this group (in addition to the group name).")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)

                    TextField("e.g. piano, organ, glock", text: $draftKeywords, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...4)
                        .padding(AppSpacing.sm)
                        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                        .focused($focusedField, equals: .keywords)
                        .onSubmit(commitKeywords)
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
        .onAppear {
            draftName = group.name
            draftKeywords = group.nameKeywords
        }
        .onChange(of: group.name) { _, newValue in
            if focusedField != .name {
                draftName = newValue
            }
        }
        .onChange(of: group.nameKeywords) { _, newValue in
            if focusedField != .keywords {
                draftKeywords = newValue
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .name, newValue != .name {
                commitName()
            }
            if oldValue == .keywords, newValue != .keywords {
                commitKeywords()
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                commitName()
                commitKeywords()
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8),
                spacing: 6
            ) {
                ForEach(TrackGroupPalette.Key.allCases) { key in
                    let isSelected = group.paletteKey == key.rawValue
                    Button {
                        group.paletteKey = key.rawValue
                        try? modelContext.save()
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(key.color)
                            .frame(height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? AppColors.accent : AppColors.separator.opacity(0.5),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(key.displayName)
                }
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

    private func commitKeywords() {
        let keywords = draftKeywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        group.setKeywordList(keywords)
        draftKeywords = group.nameKeywords
        try? modelContext.save()
    }
}
