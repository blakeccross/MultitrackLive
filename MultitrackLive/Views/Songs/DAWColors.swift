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

enum TrackClipPalette {
    private static let pairs: [(header: Color, body: Color)] = [
        (Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.75, green: 0.88, blue: 0.98)),
        (Color(red: 0.85, green: 0.72, blue: 0.25), Color(red: 0.98, green: 0.95, blue: 0.75)),
        (Color(red: 0.90, green: 0.55, blue: 0.20), Color(red: 0.98, green: 0.88, blue: 0.72)),
        (Color(red: 0.85, green: 0.35, blue: 0.55), Color(red: 0.95, green: 0.82, blue: 0.88)),
        (Color(red: 0.25, green: 0.65, blue: 0.60), Color(red: 0.78, green: 0.92, blue: 0.88)),
        (Color(red: 0.50, green: 0.35, blue: 0.85), Color(red: 0.88, green: 0.82, blue: 0.98)),
    ]

    static func colors(for index: Int) -> (header: Color, body: Color) {
        pairs[abs(index) % pairs.count]
    }
}
