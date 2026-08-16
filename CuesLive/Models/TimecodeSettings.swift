import Foundation
import SwiftData

enum TimecodeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perSongHour
    case continuousShowTime
    case resetPerSong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .perSongHour:
            "Per-song hour"
        case .continuousShowTime:
            "Continuous show time"
        case .resetPerSong:
            "Reset per song"
        }
    }
}

enum TimecodeFrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case fps24
    case fps25
    case fps30
    case fps2997Drop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fps24:
            "24 fps"
        case .fps25:
            "25 fps"
        case .fps30:
            "30 fps"
        case .fps2997Drop:
            "29.97 fps DF"
        }
    }

    /// Nominal frames per second used for LTC bit timing and duration conversion.
    var framesPerSecond: Double {
        switch self {
        case .fps24:
            24
        case .fps25:
            25
        case .fps30:
            30
        case .fps2997Drop:
            30_000.0 / 1_001.0
        }
    }

    var isDropFrame: Bool {
        self == .fps2997Drop
    }

    /// Integer frame modulus used for non-drop timecode arithmetic (DF uses 30).
    var timecodeFramesPerSecond: Int {
        switch self {
        case .fps24:
            24
        case .fps25:
            25
        case .fps30, .fps2997Drop:
            30
        }
    }
}

@Model
final class TimecodeSettings {
    var id: UUID
    var isEnabled: Bool = false
    var modeRaw: String = TimecodeMode.resetPerSong.rawValue
    var startingHour: Int = 1
    var frameRateRaw: String = TimecodeFrameRate.fps30.rawValue

    init(
        isEnabled: Bool = false,
        mode: TimecodeMode = .resetPerSong,
        startingHour: Int = 1,
        frameRate: TimecodeFrameRate = .fps30
    ) {
        id = UUID()
        self.isEnabled = isEnabled
        modeRaw = mode.rawValue
        self.startingHour = Self.clampedHour(startingHour)
        frameRateRaw = frameRate.rawValue
    }

    var mode: TimecodeMode {
        get { TimecodeMode(rawValue: modeRaw) ?? .resetPerSong }
        set { modeRaw = newValue.rawValue }
    }

    var frameRate: TimecodeFrameRate {
        get { TimecodeFrameRate(rawValue: frameRateRaw) ?? .fps30 }
        set { frameRateRaw = newValue.rawValue }
    }

    static func clampedHour(_ hour: Int) -> Int {
        min(23, max(0, hour))
    }
}

struct TimecodeSettingsSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var mode: TimecodeMode
    var startingHour: Int
    var frameRate: TimecodeFrameRate

    static let `default` = TimecodeSettingsSnapshot(
        isEnabled: false,
        mode: .resetPerSong,
        startingHour: 1,
        frameRate: .fps30
    )

    init(
        isEnabled: Bool,
        mode: TimecodeMode,
        startingHour: Int,
        frameRate: TimecodeFrameRate
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.startingHour = TimecodeSettings.clampedHour(startingHour)
        self.frameRate = frameRate
    }

    init(_ settings: TimecodeSettings) {
        self.init(
            isEnabled: settings.isEnabled,
            mode: settings.mode,
            startingHour: settings.startingHour,
            frameRate: settings.frameRate
        )
    }
}
