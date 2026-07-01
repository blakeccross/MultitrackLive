import SwiftUI

struct LiveSetlistNowPlayingInfoView: View {
    let coordinator: PlaybackCoordinator
    @Bindable var audioEngine: AudioEngineManager
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
            if audioEngine.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    transportContent(at: audioEngine.livePlayheadTime())
                }
            } else {
                transportContent(at: audioEngine.currentTime)
            }
        }
    }

    private func transportContent(at time: TimeInterval) -> some View {
        let snapshot = displaySnapshot(at: time)
        let transportButtonSize = max(infoPanelHeight, 44)

        return HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                AppIconButton(
                    systemImage: "stop.fill",
                    size: transportButtonSize,
                    isEnabled: isLoaded,
                    accessibilityLabel: "Stop"
                ) {
                    onStop()
                }

                AppIconButton(
                    systemImage: audioEngine.isPlaying ? "pause.fill" : "play.fill",
                    size: transportButtonSize,
                    isActive: audioEngine.isPlaying,
                    isEnabled: isLoaded,
                    cornerRadius: transportButtonSize * 0.25,
                    activeBackgroundColor: Color(red: 0.22, green: 0.82, blue: 0.36),
                    accessibilityLabel: audioEngine.isPlaying ? "Pause" : "Play"
                ) {
                    if audioEngine.isPlaying {
                        onPause()
                    } else {
                        onPlay()
                    }
                }

                AppIconButton(
                    systemImage: "repeat",
                    size: transportButtonSize,
                    isActive: sectionLoop.isLooping,
                    isEnabled: isLoaded && canLoop,
                    cornerRadius: transportButtonSize * 0.25,
                    activeBackgroundColor: AppColors.accent,
                    accessibilityLabel: sectionLoop.isLooping ? "End Loop" : "Loop Section"
                ) {
                    onToggleLoop()
                }
            }

            TransportStatusReadout(
                position: snapshot.position,
                bpm: snapshot.bpm,
                meter: snapshot.meter,
                key: snapshot.key
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: InfoPanelHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(InfoPanelHeightPreferenceKey.self) { height in
                if height > 0 {
                    infoPanelHeight = height
                }
            }
        }
    }

    private func displaySnapshot(at time: TimeInterval) -> DisplaySnapshot {
        guard let song = coordinator.currentSong else {
            return DisplaySnapshot(
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

        return DisplaySnapshot(
            position: MeasureTiming.formatTransportPosition(position),
            bpm: String(format: "%.1f", bpm),
            meter: "\(signature.numerator) / \(signature.denominator)",
            key: "-"
        )
    }
}

private struct InfoPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DisplaySnapshot {
    let position: String
    let bpm: String
    let meter: String
    let key: String
}
