import AVFoundation
import CoreGraphics
import Foundation

enum AudioTimelineMath {
    /// Converts a timeline offset (relative to trim start) to an absolute file frame index.
    static func frame(
        timelineOffset: TimeInterval,
        trimStart: TimeInterval,
        sampleRate: Double
    ) -> AVAudioFramePosition {
        AVAudioFramePosition(((trimStart + timelineOffset) * sampleRate).rounded(.toNearestOrAwayFromZero))
    }

    /// Snaps a timeline time to the nearest sample boundary.
    static func quantize(_ seconds: TimeInterval, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return seconds }
        return Double((seconds * sampleRate).rounded(.toNearestOrAwayFromZero)) / sampleRate
    }

    static func timelineOffset(
        fromFrame frame: AVAudioFramePosition,
        trimStart: TimeInterval,
        sampleRate: Double
    ) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frame) / sampleRate - trimStart
    }
}

enum TimelineLayout {
    static let basePixelsPerSecond: CGFloat = 6
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 8
    static let minimumContentWidth: CGFloat = 320

    static let laneHeight: CGFloat = 94
    static let sectionMarkerHeight: CGFloat = 22
    static let rulerHeight: CGFloat = 28
    static let trackHeaderWidth: CGFloat = 204

    static var rulerTotalHeight: CGFloat {
        sectionMarkerHeight + rulerHeight
    }

    static func pixelsPerSecond(zoom: CGFloat) -> CGFloat {
        basePixelsPerSecond * zoom
    }

    static func contentWidth(for duration: TimeInterval, zoom: CGFloat = 1) -> CGFloat {
        max(minimumContentWidth, CGFloat(max(duration, 1)) * pixelsPerSecond(zoom: zoom))
    }

    static func xPosition(for time: TimeInterval, duration: TimeInterval, contentWidth: CGFloat) -> CGFloat {
        let safeDuration = max(duration, 0.001)
        return contentWidth * CGFloat(max(0, time) / safeDuration)
    }

    static func time(at x: CGFloat, duration: TimeInterval, contentWidth: CGFloat) -> TimeInterval {
        let safeDuration = max(duration, 0.001)
        guard contentWidth > 0 else { return 0 }
        let clampedX = min(max(0, x), contentWidth)
        return safeDuration * TimeInterval(clampedX / contentWidth)
    }
}

enum MeasureTiming {
    static let beatsPerMeasure: Double = 4

    static func measureDuration(bpm: Double) -> TimeInterval {
        guard bpm > 0 else { return 0 }
        return beatsPerMeasure * 60.0 / bpm
    }

    /// Returns the timeline time at the end of the measure containing `time`.
    static func endOfCurrentMeasure(at time: TimeInterval, bpm: Double) -> TimeInterval {
        let duration = measureDuration(bpm: bpm)
        guard duration > 0 else { return time }
        let measureIndex = floor(max(0, time) / duration)
        return (measureIndex + 1) * duration
    }
}
