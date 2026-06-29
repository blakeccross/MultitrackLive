import SwiftUI

struct AppListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var isSelected: Bool = false
    var isDimmed: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        isDimmed: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.accent)
                    .frame(width: 3, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isSelected ? .body.weight(.semibold) : .body)
                    .foregroundStyle(isDimmed ? AppColors.textTertiary : AppColors.textPrimary)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: AppSpacing.rowMinHeight)
        .background(
            isSelected ? AppColors.surfaceElevated : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        )
        .opacity(isDimmed ? 0.55 : 1)
    }
}
