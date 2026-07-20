import SwiftUI

struct TransportStatusSnapshot {
    let position: String
    let bpm: String
    let meter: String
    let key: String
}

struct SharedTransportStrip: View {
    let snapshot: TransportStatusSnapshot
    let buttonSize: CGFloat
    let isPlaying: Bool
    let isLoaded: Bool
    let isLooping: Bool
    let canLoop: Bool
    let onStop: () -> Void
    let onPlay: () -> Void
    let onPause: () -> Void
    let onToggleLoop: () -> Void
    var onTapBPM: (() -> Void)? = nil
    var onTapMeter: (() -> Void)? = nil
    var onReadoutHeightChange: ((CGFloat) -> Void)? = nil

    private static let transportActiveGreen = Color(red: 0.49, green: 0.75, blue: 0.48)

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                AppIconButton(
                    systemImage: "stop.fill",
                    size: buttonSize,
                    isEnabled: isLoaded,
                    accessibilityLabel: "Stop"
                ) {
                    onStop()
                }

                AppIconButton(
                    systemImage: isPlaying ? "pause.fill" : "play.fill",
                    size: buttonSize,
                    isActive: isPlaying,
                    isEnabled: isLoaded,
                    cornerRadius: buttonSize * 0.14,
                    activeBackgroundColor: Self.transportActiveGreen,
                    accessibilityLabel: isPlaying ? "Pause" : "Play"
                ) {
                    if isPlaying {
                        onPause()
                    } else {
                        onPlay()
                    }
                }

                AppIconButton(
                    systemImage: "repeat",
                    size: buttonSize,
                    isActive: isLooping,
                    isEnabled: isLoaded && canLoop,
                    cornerRadius: buttonSize * 0.14,
                    accessibilityLabel: isLooping ? "End Loop" : "Loop Section"
                ) {
                    onToggleLoop()
                }
            }

            TransportStatusReadout(
                position: snapshot.position,
                bpm: snapshot.bpm,
                meter: snapshot.meter,
                key: snapshot.key,
                onTapBPM: onTapBPM,
                onTapMeter: onTapMeter
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SharedTransportReadoutHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(SharedTransportReadoutHeightPreferenceKey.self) { height in
                guard height > 0 else { return }
                onReadoutHeightChange?(height)
            }
        }
    }
}

private struct SharedTransportReadoutHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
