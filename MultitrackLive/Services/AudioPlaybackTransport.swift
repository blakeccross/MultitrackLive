import AVFoundation
import Foundation
import os

/// Sample-accurate shared transport clock used by all track source nodes.
final class AudioPlaybackTransport: @unchecked Sendable {
    struct PendingTransition: Sendable {
        let transitionAt: TimeInterval
        let targetOffset: TimeInterval
    }

    struct RenderState: Sendable {
        let timelineSeconds: TimeInterval
        let isPlaying: Bool
        let playbackRatio: Double
    }

    private var lock = os_unfair_lock()
    private static var hostTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0

    private var pausedTimeline: TimeInterval = 0
    private var anchorTimeline: TimeInterval = 0
    private var anchorHostTime: UInt64 = 0
    private var hasAnchor = false
    private var pendingTransition: PendingTransition?
    private var tempoPlaybackMap = TempoPlaybackMap(segments: [])
    private var usesTempoMap = false

    func setDuration(_ duration: TimeInterval) {
        os_unfair_lock_lock(&lock)
        self.duration = max(0, duration)
        os_unfair_lock_unlock(&lock)
    }

    func setPausedTimeline(_ timeline: TimeInterval) {
        os_unfair_lock_lock(&lock)
        pausedTimeline = max(0, min(timeline, duration))
        os_unfair_lock_unlock(&lock)
    }

    func pausedTimelineSeconds() -> TimeInterval {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pausedTimeline
    }

    func beginPlayback(from timeline: TimeInterval) {
        os_unfair_lock_lock(&lock)
        pausedTimeline = max(0, min(timeline, duration))
        anchorTimeline = pausedTimeline
        hasAnchor = false
        isPlaying = true
        os_unfair_lock_unlock(&lock)
    }

    func pause(capturingTimeline timeline: TimeInterval) {
        os_unfair_lock_lock(&lock)
        pausedTimeline = max(0, min(timeline, duration))
        isPlaying = false
        hasAnchor = false
        os_unfair_lock_unlock(&lock)
    }

    func stop() {
        os_unfair_lock_lock(&lock)
        pausedTimeline = 0
        anchorTimeline = 0
        isPlaying = false
        hasAnchor = false
        pendingTransition = nil
        os_unfair_lock_unlock(&lock)
    }

    func scheduleTransition(to targetOffset: TimeInterval, at transitionTimelineTime: TimeInterval) {
        os_unfair_lock_lock(&lock)
        let target = max(0, min(targetOffset, duration))
        let transitionAt = max(0, min(transitionTimelineTime, duration))
        pendingTransition = PendingTransition(transitionAt: transitionAt, targetOffset: target)
        os_unfair_lock_unlock(&lock)
    }

    func cancelScheduledTransition() {
        os_unfair_lock_lock(&lock)
        pendingTransition = nil
        os_unfair_lock_unlock(&lock)
    }

    func setTempoMap(
        changes: [TempoChange],
        referenceBPM: Double,
        timeSignatureChanges: [TimeSignatureChange],
        duration: TimeInterval
    ) {
        os_unfair_lock_lock(&lock)
        tempoPlaybackMap = TempoPlaybackMap.build(
            tempoChanges: changes.sortedByMeasure,
            referenceBPM: referenceBPM,
            timeSignatureChanges: timeSignatureChanges,
            maxSourceTime: max(duration, 1)
        )
        usesTempoMap = referenceBPM > 0 && !changes.isEmpty
        os_unfair_lock_unlock(&lock)
    }

    func clearScheduledTransition() {
        os_unfair_lock_lock(&lock)
        pendingTransition = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Single locked read used by each track source node.
    func renderTimeline(atHostTime hostTime: UInt64, captureAnchor: Bool) -> RenderState {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if captureAnchor, isPlaying, !hasAnchor {
            anchorHostTime = hostTime
            hasAnchor = true
        }

        guard isPlaying else {
            return RenderState(timelineSeconds: pausedTimeline, isPlaying: false, playbackRatio: 1.0)
        }

        guard hasAnchor else {
            return RenderState(timelineSeconds: pausedTimeline, isPlaying: true, playbackRatio: 1.0)
        }

        let elapsed = Self.seconds(fromHostTimeDelta: hostTime &- anchorHostTime)
        let timeline: TimeInterval
        if usesTempoMap {
            timeline = tempoPlaybackMap.sourceTimeAfterWallElapsed(
                from: anchorTimeline,
                wallElapsed: elapsed
            )
        } else {
            timeline = anchorTimeline + elapsed
        }
        let mapped = mappedTimeline(fromLinear: timeline)
        let clamped = max(0, min(mapped, duration))
        let ratio = usesTempoMap ? tempoPlaybackMap.ratio(at: clamped) : 1.0
        return RenderState(timelineSeconds: clamped, isPlaying: true, playbackRatio: ratio)
    }

    func timelineSeconds(atHostTime hostTime: UInt64) -> TimeInterval {
        renderTimeline(atHostTime: hostTime, captureAnchor: false).timelineSeconds
    }

    func playbackRatio(at timeline: TimeInterval) -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard usesTempoMap else { return 1.0 }
        return tempoPlaybackMap.ratio(at: timeline)
    }

    func mappedTimeline(fromLinear linear: TimeInterval) -> TimeInterval {
        if let pendingTransition, linear >= pendingTransition.transitionAt {
            let jumped = pendingTransition.targetOffset + (linear - pendingTransition.transitionAt)
            return max(0, min(jumped, duration))
        }
        return linear
    }

    func resetAnchor(to timeline: TimeInterval, hostTime: UInt64) {
        os_unfair_lock_lock(&lock)
        anchorTimeline = max(0, min(timeline, duration))
        pausedTimeline = anchorTimeline
        anchorHostTime = hostTime
        hasAnchor = true
        os_unfair_lock_unlock(&lock)
    }

    private static func seconds(fromHostTimeDelta delta: UInt64) -> TimeInterval {
        let nanos = Double(delta) * Double(hostTimebase.numer) / Double(hostTimebase.denom)
        return nanos / 1_000_000_000
    }
}
