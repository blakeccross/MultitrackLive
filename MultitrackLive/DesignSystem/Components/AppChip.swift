import SwiftUI

struct AppChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                .background(
                    isSelected ? AppColors.accent : AppColors.surface,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .appPressable()
    }
}
