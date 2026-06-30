import SwiftUI

struct AppPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(minHeight: 44)
                .background(AppColors.accent.opacity(isEnabled ? 1 : 0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .appPressable(isEnabled: isEnabled)
    }
}

struct AppSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .background(AppColors.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .appPressable(isEnabled: isEnabled)
    }
}

struct AppIconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var isActive: Bool = false
    var isEnabled: Bool = true
    var cornerRadius: CGFloat? = nil
    var activeBackgroundColor: Color? = nil
    var accessibilityLabel: String? = nil
    let action: () -> Void

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? AppRadius.sm, style: .continuous)
    }

    private var backgroundColor: Color {
        if isActive, let activeBackgroundColor {
            return activeBackgroundColor
        }
        return AppColors.surfaceElevated
    }

    private var foregroundColor: Color {
        if isActive, activeBackgroundColor != nil {
            return Color.black.opacity(0.85)
        }
        if isActive {
            return AppColors.accent
        }
        return AppColors.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(backgroundColor, in: buttonShape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .appPressable(isEnabled: isEnabled)
        .accessibilityLabel(accessibilityLabel ?? systemImage)
    }
}
