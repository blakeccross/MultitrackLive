import SwiftUI

extension ToolbarContent {
    /// Hides Liquid Glass shared item backgrounds when building with the 26+ SDK.
    @ToolbarContentBuilder
    func cuesHideSharedBackground() -> some ToolbarContent {
#if CUESLIVE_TOOLBAR_GLASS_SDK26
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
