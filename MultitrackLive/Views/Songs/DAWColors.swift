import SwiftUI

extension Color {
    static var dawTimelineBackground: Color {
        AppColors.backgroundPrimary
    }

    /// Fully opaque background for pinned ruler headers so scrolling tracks don't show through.
    static var dawStickyRulerBackground: Color {
        AppColors.surfaceElevated
    }

    static var dawTrackHeaderBackground: Color {
        AppColors.backgroundSecondary
    }

    static var dawTrackHeaderColumnBackground: Color {
        AppColors.backgroundPrimary
    }

    static var dawTimelineDivider: Color {
        AppColors.separator
    }

    static var dawMixButtonBackground: Color {
        AppColors.surface
    }

    static var dawSoloActive: Color {
        AppColors.soloActive
    }

    static var dawMuteActive: Color {
        AppColors.muteActive
    }

    static var dawMeasureGridLine: Color {
        AppColors.separator.opacity(0.6)
    }

    static var dawWaveformFill: Color {
        AppColors.textSecondary.opacity(0.6)
    }

    /// Voice Memos–style live waveform colors.
    static var liveVoiceMemosPlayed: Color {
        Color(red: 1.0, green: 0.584, blue: 0.0)
    }

    static var liveVoiceMemosUnplayed: Color {
        Color(white: 0.42)
    }

    static var liveVoiceMemosBackground: Color {
        Color(white: 0.06)
    }

    static var dawTrackHeaderSelected: Color {
        AppColors.trackHeaderSelected
    }

    static var dawPlayheadFill: Color {
        Color(white: 0.82)
    }

    static var dawPlayheadBorder: Color {
        Color(white: 0.12)
    }
}

enum TrackClipPalette {
    private enum Swatch {
        // Row 1
        static let orange = Color("TrackPaletteOrange")
        static let amber = Color("TrackPaletteAmber")
        static let gold = Color("TrackPaletteGold")
        static let yellow = Color("TrackPaletteYellow")
        static let lime = Color("TrackPaletteLime")
        static let chartreuse = Color("TrackPaletteChartreuse")

        // Row 2
        static let green = Color("TrackPaletteGreen")
        static let grass = Color("TrackPaletteGrass")
        static let brightGreen = Color("TrackPaletteBrightGreen")
        static let emerald = Color("TrackPaletteEmerald")
        static let mint = Color("TrackPaletteMint")
        static let teal = Color("TrackPaletteTeal")

        // Row 3
        static let cyan = Color("TrackPaletteCyan")
        static let sky = Color("TrackPaletteSky")
        static let blue = Color("TrackPaletteBlue")
        static let indigo = Color("TrackPaletteIndigo")
        static let violet = Color("TrackPaletteViolet")
        static let purple = Color("TrackPalettePurple")

        // Row 4
        static let deepPurple = Color("TrackPaletteDeepPurple")
        static let amethyst = Color("TrackPaletteAmethyst")
        static let magenta = Color("TrackPaletteMagenta")
        static let fuchsia = Color("TrackPaletteFuchsia")
        static let hotPink = Color("TrackPaletteHotPink")
        static let pink = Color("TrackPalettePink")
    }

    private static let bodies: [Color] = [
        Swatch.orange, Swatch.amber, Swatch.gold, Swatch.yellow, Swatch.lime, Swatch.chartreuse,
        Swatch.green, Swatch.grass, Swatch.brightGreen, Swatch.emerald, Swatch.mint, Swatch.teal,
        Swatch.cyan, Swatch.sky, Swatch.blue, Swatch.indigo, Swatch.violet, Swatch.purple,
        Swatch.deepPurple, Swatch.amethyst, Swatch.magenta, Swatch.fuchsia, Swatch.hotPink, Swatch.pink,
    ]

    private static let headerDarkenFactor = 0.72

    static func colors(for index: Int) -> (header: Color, body: Color) {
        let body = bodies[abs(index) % bodies.count]
        return (body.darkened(sRGBBy: headerDarkenFactor), body)
    }
}
