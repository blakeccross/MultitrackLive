import SwiftUI

struct AppCard<Content: View>: View {
    var padding: CGFloat = AppSpacing.md
    var radius: CGFloat = AppRadius.md
    var background: Color = AppColors.surfaceElevated
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, padding)
            .padding(.vertical, padding * 0.5)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
