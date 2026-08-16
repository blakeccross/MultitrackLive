import SwiftUI

private let mixerMeterGreen = Color(red: 0.22, green: 0.82, blue: 0.36)

struct TrackMixButton: View {
    let label: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 22, height: 20)
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : AppColors.textSecondary)
                .background(isActive ? activeColor : AppColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .appPressable()
    }
}

struct LogicStyleVolumeSlider: View {
    @Binding var value: Double
    let meterLevel: Float
    let onEditingEnded: () -> Void

    @State private var isDragging = false

    private let controlHeight: CGFloat = 26
    private let meterBarHeight: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let travel = max(trackWidth - controlHeight, 1)
            let thumbCenterX = controlHeight / 2 + CGFloat(value) * travel
            let thumbX = thumbCenterX - controlHeight / 2
            let meterWidth = trackWidth * MixerFaderScale.meterFillFraction(forPeak: meterLevel)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.separator.opacity(0.45))
                    .frame(height: controlHeight)

                meterBars(width: meterWidth)
                    .padding(.leading, 8)
                    .frame(height: controlHeight, alignment: .center)
                    .clipShape(Capsule())

                Circle()
                    .fill(isDragging ? Color.white.opacity(0.60) : Color.white.opacity(0.45))
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    }
                    .frame(width: controlHeight, height: controlHeight)
                    .offset(x: thumbX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        setValue(fromCenterX: drag.location.x, trackWidth: trackWidth, travel: travel)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingEnded()
                    }
            )
        }
        .frame(height: controlHeight)
    }

    private func meterBars(width: CGFloat) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(mixerMeterGreen)
                .frame(width: max(0, width - 8), height: meterBarHeight)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(mixerMeterGreen)
                .frame(width: max(0, width - 8), height: meterBarHeight)
        }
    }

    private func setValue(fromCenterX x: CGFloat, trackWidth: CGFloat, travel: CGFloat) {
        let clampedCenter = min(max(x, controlHeight / 2), trackWidth - controlHeight / 2)
        let normalized = Double((clampedCenter - controlHeight / 2) / travel)
        value = min(1, max(0, normalized))
    }
}

enum MixerFaderScale {
    static let maxAttenuationDB: Double = 60

    static func linearGain(forAttenuationDB db: Double) -> Double {
        pow(10, -db / 20)
    }

    static func attenuationDB(forLinearGain gain: Double) -> Double {
        guard gain > 0.000_001 else { return maxAttenuationDB }
        return min(maxAttenuationDB, max(0, -20 * log10(gain)))
    }

    static func normalizedPosition(forLinearGain gain: Double) -> Double {
        attenuationDB(forLinearGain: gain) / maxAttenuationDB
    }

    static func linearGain(forNormalizedPosition position: Double) -> Double {
        linearGain(forAttenuationDB: position * maxAttenuationDB)
    }

    static func meterFillFraction(forPeak peak: Float) -> CGFloat {
        guard peak > 0.000_001 else { return 0 }
        let db = min(maxAttenuationDB, max(0, -20 * log10(Double(peak))))
        return CGFloat(1 - (db / maxAttenuationDB))
    }
}

struct MixerFaderColumn: View {
    @Binding var value: Double
    let groupID: UUID?
    let height: CGFloat
    /// Audible mix only — must not write SwiftData (avoids @Query rebuilds mid-drag).
    let onLiveVolumeChange: (Double) -> Void
    let onEditingEnded: () -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private let trackWidth: CGFloat = 4
    private let thumbWidth: CGFloat = 52
    private let thumbHeight: CGFloat = 28
    private let meterWidth: CGFloat = 5
    private let tickCount = 10
    private let tickWidth: CGFloat = 8
    private let tickGapFromTrack: CGFloat = 4

    private var displayedValue: Double {
        isDragging ? dragValue : value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            faderTrack
            GroupPeakMeterBar(groupID: groupID, width: meterWidth, height: height)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: height)
    }

    private var faderTrack: some View {
        GeometryReader { geometry in
            let trackHeight = geometry.size.height
            let travel = max(trackHeight - thumbHeight, 1)
            let thumbCenterY = markY(
                forNormalized: MixerFaderScale.normalizedPosition(forLinearGain: displayedValue),
                in: trackHeight
            )
            let thumbY = thumbCenterY - thumbHeight / 2

            ZStack(alignment: .top) {
                scaleTicks(in: trackHeight)

                RoundedRectangle(cornerRadius: trackWidth / 2, style: .continuous)
                    .fill(AppColors.separator)
                    .frame(width: trackWidth)
                    .frame(maxHeight: .infinity)

                faderThumb
                    .offset(y: thumbY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            dragValue = value
                            isDragging = true
                        }
                        setLiveValue(fromCenterY: drag.location.y, trackHeight: trackHeight, travel: travel)
                    }
                    .onEnded { _ in
                        if isDragging {
                            value = dragValue
                        }
                        isDragging = false
                        onEditingEnded()
                    }
            )
        }
        .frame(width: thumbWidth)
        .transaction { transaction in
            if isDragging {
                transaction.disablesAnimations = true
            }
        }
    }

    private var faderThumb: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(AppColors.backgroundPrimary)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(AppColors.textTertiary.opacity(0.35))
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 6)
            }
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
            .frame(width: thumbWidth, height: thumbHeight)
    }

    private func scaleTicks(in trackHeight: CGFloat) -> some View {
        let centerX = thumbWidth / 2
        let trackHalf = trackWidth / 2
        let tickColor = AppColors.textTertiary.opacity(0.6)

        return ZStack(alignment: .topLeading) {
            ForEach(0..<tickCount, id: \.self) { index in
                let y = markY(
                    forNormalized: Double(index) / Double(tickCount - 1),
                    in: trackHeight
                )

                Rectangle()
                    .fill(tickColor)
                    .frame(width: tickWidth, height: 1)
                    .offset(x: centerX - trackHalf - tickGapFromTrack - tickWidth, y: y)

                Rectangle()
                    .fill(tickColor)
                    .frame(width: tickWidth, height: 1)
                    .offset(x: centerX + trackHalf + tickGapFromTrack, y: y)
            }
        }
        .frame(width: thumbWidth, height: trackHeight, alignment: .topLeading)
    }

    private func markY(forNormalized normalized: Double, in trackHeight: CGFloat) -> CGFloat {
        thumbHeight / 2 + CGFloat(normalized) * max(trackHeight - thumbHeight, 1)
    }

    private func setLiveValue(fromCenterY y: CGFloat, trackHeight: CGFloat, travel: CGFloat) {
        let clampedCenter = min(max(y, thumbHeight / 2), trackHeight - thumbHeight / 2)
        let normalized = Double((clampedCenter - thumbHeight / 2) / travel)
        let newValue = MixerFaderScale.linearGain(forNormalizedPosition: normalized)
        dragValue = newValue
        onLiveVolumeChange(newValue)
    }
}

/// Reads peak meters in isolation so 30 Hz updates don't rebuild parent fader geometry.
private struct GroupPeakMeterBar: View {
    let groupID: UUID?
    let width: CGFloat
    let height: CGFloat

    @Bindable private var audioEngine = AudioEngineManager.shared

    var body: some View {
        let meterLevel = audioEngine.groupMeterLevel(for: groupID)

        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.separator)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(mixerMeterGreen.opacity(0.85))
                    .frame(height: geometry.size.height * MixerFaderScale.meterFillFraction(forPeak: meterLevel))
            }
        }
        .frame(width: width, height: height)
    }
}
