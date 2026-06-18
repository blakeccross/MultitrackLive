import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static var dawLaneBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var dawTimelineBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor).opacity(0.6)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// Fully opaque background for pinned ruler headers so scrolling tracks don't show through.
    static var dawStickyRulerBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var dawTrackHeaderBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var dawTrackHeaderColumnBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var dawTimelineDivider: Color {
        Color.primary.opacity(0.12)
    }

    static var dawMixButtonBackground: Color {
        Color.primary.opacity(0.1)
    }

    static var dawSoloActive: Color {
        Color(red: 0.98, green: 0.82, blue: 0.08)
    }

    static var dawMuteActive: Color {
        Color(red: 0.95, green: 0.45, blue: 0.32)
    }

    static var dawClipBackground: Color {
        Color.blue.opacity(0.22)
    }

    static var dawClipBackgroundSelected: Color {
        Color.blue.opacity(0.38)
    }

    static var dawClipBorder: Color {
        Color.blue.opacity(0.9)
    }

    static var dawClipSideBorder: Color {
        Color.blue.opacity(0.48)
    }

    static var dawMeasureGridLine: Color {
        Color.primary.opacity(0.1)
    }

    static var dawWaveformFill: Color {
        Color.blue.opacity(0.72)
    }
}
