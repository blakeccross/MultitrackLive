import SwiftUI

struct AppSheetContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(AppColors.backgroundSecondary)
            #if os(iOS)
            .presentationBackground(AppColors.backgroundSecondary)
            #endif
    }
}
