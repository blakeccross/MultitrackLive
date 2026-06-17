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

    static let laneHeight: CGFloat = 104
    static let laneSpacing: CGFloat = 4
    static let sectionMarkerHeight: CGFloat = 22
    static let tempoRulerHeight: CGFloat = 24
    static let rulerHeight: CGFloat = 28
    static let trackHeaderWidth: CGFloat = 204

    static var rulerTotalHeight: CGFloat {
        sectionMarkerHeight + tempoRulerHeight + rulerHeight
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
    static let defaultNumerator = 4
    static let defaultDenominator = 4

    static func beatsPerMeasure(numerator: Int, denominator: Int) -> Double {
        guard numerator > 0, denominator > 0 else { return 4 }
        return Double(numerator) * 4.0 / Double(denominator)
    }

    /// Measure boundary times for grid lines, thinning when zoomed out.
    static func visibleMeasureBoundaries(
        duration: TimeInterval,
        bpm: Double,
        contentWidth: CGFloat,
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator,
        minimumPixelSpacing: CGFloat = 10
    ) -> [TimeInterval] {
        visibleMeasureBoundaries(
            duration: duration,
            tempoChanges: [TempoChange(startMeasure: 1, bpm: bpm)],
            contentWidth: contentWidth,
            numerator: numerator,
            denominator: denominator,
            minimumPixelSpacing: minimumPixelSpacing
        )
    }

    static func visibleMeasureBoundaries(
        duration: TimeInterval,
        tempoChanges: [TempoChange],
        contentWidth: CGFloat,
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator,
        minimumPixelSpacing: CGFloat = 10
    ) -> [TimeInterval] {
        let safeDuration = max(duration, 0.001)
        guard safeDuration > 0, contentWidth > 0, !tempoChanges.isEmpty else { return [] }

        var boundaries: [TimeInterval] = []
        var measure = 2
        while true {
            let time = timeAtStartOfMeasure(
                measure,
                tempoChanges: tempoChanges,
                numerator: numerator,
                denominator: denominator
            )
            guard time < safeDuration - 0.0001 else { break }
            boundaries.append(time)
            measure += 1
        }

        guard let first = boundaries.first else { return [] }
        let pixelsPerMeasure = CGFloat(first) * contentWidth / CGFloat(safeDuration)
        let stride = max(1, Int(ceil(minimumPixelSpacing / max(pixelsPerMeasure, 0.001))))
        guard stride > 1 else { return boundaries }

        return boundaries.enumerated().compactMap { index, time in
            (index + 1) % stride == 0 ? time : nil
        }
    }

    static func measureDuration(
        bpm: Double,
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator
    ) -> TimeInterval {
        guard bpm > 0 else { return 0 }
        return beatsPerMeasure(numerator: numerator, denominator: denominator) * 60.0 / bpm
    }

    static func bpmForMeasure(
        _ measure: Int,
        tempoChanges: [TempoChange]
    ) -> Double {
        tempoChanges.sortedByMeasure.active(atMeasure: measure)?.bpm ?? TempoChange.defaultBPM
    }

    static func timeAtStartOfMeasure(
        _ measure: Int,
        tempoChanges: [TempoChange],
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator
    ) -> TimeInterval {
        guard measure > 1 else { return 0 }

        var time: TimeInterval = 0
        for index in 1..<measure {
            let bpm = bpmForMeasure(index, tempoChanges: tempoChanges)
            time += measureDuration(bpm: bpm, numerator: numerator, denominator: denominator)
        }
        return time
    }

    static func measureIndex(
        at time: TimeInterval,
        tempoChanges: [TempoChange],
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator
    ) -> Int {
        guard time > 0, !tempoChanges.isEmpty else { return 1 }

        var measure = 1
        var elapsed: TimeInterval = 0

        while measure < 1_000_000 {
            let bpm = bpmForMeasure(measure, tempoChanges: tempoChanges)
            let duration = measureDuration(bpm: bpm, numerator: numerator, denominator: denominator)
            guard duration > 0 else { return measure }
            if time < elapsed + duration - 0.0001 {
                return measure
            }
            elapsed += duration
            measure += 1
        }

        return measure
    }

    static func activeBPM(
        at time: TimeInterval,
        tempoChanges: [TempoChange],
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator
    ) -> Double {
        let measure = measureIndex(at: time, tempoChanges: tempoChanges, numerator: numerator, denominator: denominator)
        return bpmForMeasure(measure, tempoChanges: tempoChanges)
    }

    static func nearestMeasureBoundary(
        to time: TimeInterval,
        tempoChanges: [TempoChange],
        numerator: Int = defaultNumerator,
        denominator: Int = defaultDenominator
    ) -> (measure: Int, time: TimeInterval) {
        let measure = measureIndex(at: max(0, time), tempoChanges: tempoChanges, numerator: numerator, denominator: denominator)
        let start = timeAtStartOfMeasure(measure, tempoChanges: tempoChanges, numerator: numerator, denominator: denominator)
        let nextMeasure = measure + 1
        let nextStart = timeAtStartOfMeasure(nextMeasure, tempoChanges: tempoChanges, numerator: numerator, denominator: denominator)

        if time - start <= nextStart - time {
            return (measure, start)
        }
        return (nextMeasure, nextStart)
    }
}

/// Precomputed tempo segments for O(markers) playback integration on the audio thread.
struct TempoPlaybackMap: Sendable {
    struct Segment: Sendable {
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let ratio: Double
    }

    let segments: [Segment]

    static let defaultMaxSourceTime: TimeInterval = 86_400

    static func build(
        tempoChanges: [TempoChange],
        referenceBPM: Double,
        numerator: Int = MeasureTiming.defaultNumerator,
        denominator: Int = MeasureTiming.defaultDenominator,
        maxSourceTime: TimeInterval = defaultMaxSourceTime
    ) -> TempoPlaybackMap {
        guard referenceBPM > 0, !tempoChanges.isEmpty else {
            return TempoPlaybackMap(segments: [])
        }

        let markers = tempoChanges.sortedByMeasure
        var segments: [Segment] = []

        for (index, marker) in markers.enumerated() {
            let sourceStart = MeasureTiming.timeAtStartOfMeasure(
                marker.startMeasure,
                tempoChanges: markers,
                numerator: numerator,
                denominator: denominator
            )
            let sourceEnd: TimeInterval
            if index + 1 < markers.count {
                sourceEnd = MeasureTiming.timeAtStartOfMeasure(
                    markers[index + 1].startMeasure,
                    tempoChanges: markers,
                    numerator: numerator,
                    denominator: denominator
                )
            } else {
                sourceEnd = max(maxSourceTime, sourceStart + 1)
            }

            guard sourceEnd > sourceStart else { continue }
            segments.append(
                Segment(
                    sourceStart: sourceStart,
                    sourceEnd: sourceEnd,
                    ratio: marker.bpm / referenceBPM
                )
            )
        }

        return TempoPlaybackMap(segments: segments)
    }

    func sourceTimeAfterWallElapsed(from anchor: TimeInterval, wallElapsed: TimeInterval) -> TimeInterval {
        guard wallElapsed > 0, !segments.isEmpty else { return max(0, anchor) }

        var wall = wallElapsed
        var source = max(0, anchor)
        var segmentIndex = segmentIndex(for: source)

        while wall > 0.000_000_1, segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            source = max(source, segment.sourceStart)

            let remainingSource = segment.sourceEnd - source
            guard remainingSource > 0 else {
                segmentIndex += 1
                continue
            }

            let wallForRemainder = remainingSource / segment.ratio
            if wall <= wallForRemainder + 0.000_000_1 {
                return min(segment.sourceEnd, source + wall * segment.ratio)
            }

            wall -= wallForRemainder
            source = segment.sourceEnd
            segmentIndex += 1
        }

        return source
    }

    func ratio(at sourceTime: TimeInterval) -> Double {
        guard !segments.isEmpty else { return 1.0 }
        let time = max(0, sourceTime)
        if let segment = segments.last(where: { time >= $0.sourceStart - 0.000_1 && time < $0.sourceEnd - 0.000_1 }) {
            return segment.ratio
        }
        return segments.last?.ratio ?? 1.0
    }

    private func segmentIndex(for sourceTime: TimeInterval) -> Int {
        guard !segments.isEmpty else { return 0 }
        for (index, segment) in segments.enumerated() {
            if sourceTime < segment.sourceEnd - 0.000_1 {
                return index
            }
        }
        return segments.count - 1
    }
}
