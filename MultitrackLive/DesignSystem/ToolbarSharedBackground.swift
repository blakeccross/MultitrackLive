import SwiftUI

extension ToolbarContent {
    /// Hides Liquid Glass shared item backgrounds when building with the 26+ SDK.
    @ToolbarContentBuilder
    func multitrackHideSharedBackground() -> some ToolbarContent {
#if MTLIVE_TOOLBAR_GLASS_SDK26
        if #available(iOS 26.0, macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
#else
        self
#endif
    }
}
