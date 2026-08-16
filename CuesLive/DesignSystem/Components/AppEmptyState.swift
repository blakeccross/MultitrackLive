import SwiftUI

struct AppEmptyState: View {
    let title: String
    var systemImage: String = "tray"
    var description: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .foregroundStyle(AppColors.textPrimary)
        } description: {
            if let description {
                Text(description)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }
}
