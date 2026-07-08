import SwiftUI

struct LiveSetlistNowPlayingInfoView: View {
    let coordinator: PlaybackCoordinator
    @Bindable var sectionLoop: SectionLoopController
    let isLoaded: Bool
    let canLoop: Bool
    @Binding var infoPanelHeight: CGFloat
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onToggleLoop: () -> Void

    var body: some View {
        Group {
            if coordinator.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    transportContent(at: coordinator.livePlayheadTime())
                }
            } else {
                transportContent(at: coordinator.currentTime)
            }
        }
    }

    private func transportContent(at time: TimeInterval) -> some View {
        let snapshot = displaySnapshot(at: time)
        let transportButtonSize = max(infoPanelHeight, 44)

        return SharedTransportStrip(
            snapshot: snapshot,
            buttonSize: transportButtonSize,
            isPlaying: coordinator.isPlaying,
            isLoaded: isLoaded,
            isLooping: sectionLoop.isLooping,
            canLoop: canLoop,
            onStop: onStop,
            onPlay: onPlay,
            onPause: onPause,
            onToggleLoop: onToggleLoop,
            onReadoutHeightChange: { height in
                infoPanelHeight = height
            }
        )
    }

    private func displaySnapshot(at time: TimeInterval) -> TransportStatusSnapshot {
        guard let song = coordinator.currentSong else {
            return TransportStatusSnapshot(
                position: "- - -",
                bpm: "-",
                meter: "-",
                key: "-"
            )
        }

        let projectState = SongProjectBridge.projectStateOrDefaults(for: song)
        let tempoChanges = projectState.tempoChanges
        let timeSignatureChanges = projectState.timeSignatureChanges
        let position = MeasureTiming.position(
            at: time,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
        let measure = position.bar
        let signature = MeasureTiming.numeratorDenominatorForMeasure(
            measure,
            changes: timeSignatureChanges
        )
        let bpm = MeasureTiming.activeBPM(
            at: time,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )

        return TransportStatusSnapshot(
            position: MeasureTiming.formatTransportPosition(position),
            bpm: String(format: "%.1f", bpm),
            meter: "\(signature.numerator) / \(signature.denominator)",
            key: "-"
        )
    }
}
