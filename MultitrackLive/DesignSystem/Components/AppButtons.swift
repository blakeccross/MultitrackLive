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

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? max(4, size * 0.14)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
    }

    private var backgroundColor: Color {
        if isActive, let activeBackgroundColor {
            return activeBackgroundColor
        }
        return Color(red: 0.24, green: 0.25, blue: 0.26)
    }

    private var foregroundColor: Color {
        if isActive, let activeBackgroundColor {
            return activeBackgroundColor.darkened(sRGBBy: 0.42)
        }
        if isActive {
            return AppColors.accent
        }
        return Color(red: 0.78, green: 0.80, blue: 0.82)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background {
                    ZStack {
                        buttonShape
                            .fill(Color.black.opacity(0.65))
                            .offset(y: 1)

                        buttonShape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        backgroundColor,
                                        backgroundColor.darkened(sRGBBy: 0.86)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        buttonShape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.45),
                                        Color.white.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .padding(0.5)

                        buttonShape
                            .stroke(Color.black.opacity(0.9), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .appPressable(isEnabled: isEnabled)
        .accessibilityLabel(accessibilityLabel ?? systemImage)
    }
}
