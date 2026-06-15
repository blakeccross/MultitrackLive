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
    static let maxZoom: CGFloat = 8
    static let minimumContentWidth: CGFloat = 320

    /// Most zoomed-out level: entire timeline fits in the visible viewport when possible.
    static func minZoom(duration: TimeInterval, viewportWidth: CGFloat) -> CGFloat {
        guard duration > 0, viewportWidth > 0 else { return 1 }
        let naturalWidth = CGFloat(max(duration, 1)) * basePixelsPerSecond
        let floorZoom = minimumContentWidth / naturalWidth
        let fitZoom = viewportWidth / naturalWidth
        if naturalWidth > viewportWidth {
            return max(floorZoom, fitZoom)
        }
        return max(floorZoom, 1)
    }

    static let laneHeight: CGFloat = 94
    static let laneSpacing: CGFloat = 4
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

    /// Measure boundary times for grid lines, thinning when zoomed out.
    static func visibleMeasureBoundaries(
        duration: TimeInterval,
        bpm: Double,
        contentWidth: CGFloat,
        minimumPixelSpacing: CGFloat = 10
    ) -> [TimeInterval] {
        let measureDur = measureDuration(bpm: bpm)
        guard measureDur > 0, duration > 0, contentWidth > 0 else { return [] }

        let safeDuration = max(duration, 0.001)
        let pixelsPerMeasure = CGFloat(measureDur) * contentWidth / CGFloat(safeDuration)
        let stride = max(1, Int(ceil(minimumPixelSpacing / max(pixelsPerMeasure, 0.001))))

        var times: [TimeInterval] = []
        var measureIndex = stride
        while true {
            let time = Double(measureIndex) * measureDur
            guard time < safeDuration - 0.0001 else { break }
            times.append(time)
            measureIndex += stride
        }
        return times
    }
}
