import SwiftUI

struct AppBadge: View {
    let title: String
    var systemImage: String? = nil
    var style: Style = .accent

    enum Style {
        case accent
        case neutral
    }

    var body: some View {
        HStack(spacing: AppSpacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, AppSpacing.xs)
        .padding(.vertical, 5)
        .background(backgroundColor, in: Capsule())
        .overlay {
            if style == .neutral {
                Capsule()
                    .stroke(AppColors.separator, lineWidth: 1)
            }
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .accent: AppColors.textPrimary
        case .neutral: AppColors.textSecondary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .accent: AppColors.accent.opacity(0.92)
        case .neutral: AppColors.surfaceElevated
        }
    }
}
