import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppBackgroundLevel {
    case primary
    case secondary
    case surface
    case elevated
}

extension View {
    func appBackground(_ level: AppBackgroundLevel = .primary) -> some View {
        background(backgroundColor(for: level).ignoresSafeArea())
    }

    func appSeparator(alignment: Alignment = .bottom) -> some View {
        overlay(alignment: alignment) {
            Rectangle()
                .fill(AppColors.separator)
                .frame(height: 0.5)
        }
    }

    func appPressable(isEnabled: Bool = true) -> some View {
        modifier(AppPressableModifier(isEnabled: isEnabled))
    }

    func appToolbarStyle() -> some View {
        toolbarBackground(AppColors.surfaceElevated, for: .automatic)
    }

    func appEditorToolbarPill(isDisabled: Bool = false) -> some View {
        buttonStyle(.plain)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(AppColors.surfaceElevated, in: Capsule())
            .foregroundStyle(isDisabled ? AppColors.textTertiary : AppColors.textSecondary)
    }

    func appLinkPointer() -> some View {
        modifier(AppLinkPointerModifier())
    }
}

private func backgroundColor(for level: AppBackgroundLevel) -> Color {
    switch level {
    case .primary: AppColors.backgroundPrimary
    case .secondary: AppColors.backgroundSecondary
    case .surface: AppColors.surface
    case .elevated: AppColors.surfaceElevated
    }
}

private struct AppLinkPointerModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content.onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        #else
        content
        #endif
    }
}

private struct AppPressableModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && isEnabled ? 0.97 : 1)
            .animation(AppAnimation.springSnappy, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled else { return }
                        isPressed = true
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
    }
}
