import SwiftUI

struct ManageOutputsView: View {
    @Environment(\.dismiss) private var dismiss

    var onRoutingChanged: (() -> Void)?

    var body: some View {
        AppSheetContainer {
            NavigationStack {
                ScrollView {
                    OutputRoutingSettingsForm(
                        sections: .all,
                        onRoutingChanged: onRoutingChanged
                    )
                    .padding(AppSpacing.lg)
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Manage Outputs")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .foregroundStyle(AppColors.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 520, minHeight: 420, idealHeight: 560, maxHeight: 680)
        #endif
    }
}
