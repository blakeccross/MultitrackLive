import SwiftUI

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
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.primary.opacity(0.75))
                .background(isActive ? activeColor : Color.dawMixButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

struct TrackMixSliderRow: View {
    let label: String
    let valueLabel: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingEnded: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            Slider(value: $value, in: range) { editing in
                if !editing {
                    onEditingEnded()
                }
            }
            .controlSize(.mini)

            Text(valueLabel)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

enum MixerFaderScale {
    static let attenuationMarks: [Int] = [0, 6, 12, 18, 24, 30, 45, 60]
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
    let meterLevel: Float
    let height: CGFloat
    let onValueChanged: () -> Void

    private let trackWidth: CGFloat = 6
    private let thumbWidth: CGFloat = 26
    private let thumbHeight: CGFloat = 24
    private let scaleWidth: CGFloat = 20
    private let meterWidth: CGFloat = 5

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            faderTrack
            scaleColumn
            meterBar
        }
        .frame(height: height)
    }

    private var faderTrack: some View {
        GeometryReader { geometry in
            let trackHeight = geometry.size.height
            let travel = max(trackHeight - thumbHeight, 1)
            let thumbCenterY = markY(forDB: MixerFaderScale.normalizedPosition(forLinearGain: value) * MixerFaderScale.maxAttenuationDB, in: trackHeight)
            let thumbY = thumbCenterY - thumbHeight / 2

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: trackWidth / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: trackWidth)
                    .frame(maxHeight: .infinity)

                scaleTicks(in: trackHeight)

                faderThumb
                    .offset(y: thumbY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        setValue(fromCenterY: drag.location.y, trackHeight: trackHeight, travel: travel)
                    }
            )
        }
        .frame(width: thumbWidth)
    }

    private var faderThumb: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.32))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
            }
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(height: 1)
            }
            .frame(width: thumbWidth, height: thumbHeight)
    }

    private func scaleTicks(in trackHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(MixerFaderScale.attenuationMarks, id: \.self) { mark in
                let y = markY(forDB: Double(mark), in: trackHeight)
                Rectangle()
                    .fill(Color.primary.opacity(mark == 0 ? 0.35 : 0.18))
                    .frame(width: mark == 0 ? thumbWidth : 8, height: 1)
                    .offset(x: (thumbWidth - (mark == 0 ? thumbWidth : 8)) / 2, y: y)
            }
        }
    }

    private var scaleColumn: some View {
        ZStack(alignment: .topLeading) {
            ForEach(MixerFaderScale.attenuationMarks, id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 9, weight: mark == 0 ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(mark == 0 ? Color.primary : Color.secondary)
                    .frame(width: scaleWidth, alignment: .trailing)
                    .offset(y: markY(forDB: Double(mark), in: height) - 5)
            }
        }
        .frame(width: scaleWidth, height: height, alignment: .topLeading)
    }

    private var meterBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.12))

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.green.opacity(0.9))
                    .frame(height: geometry.size.height * MixerFaderScale.meterFillFraction(forPeak: meterLevel))
            }
        }
        .frame(width: meterWidth, height: height)
    }

    /// Y coordinate for a dB mark's center line, aligned with fader thumb center.
    private func markY(forDB db: Double, in trackHeight: CGFloat) -> CGFloat {
        let normalized = db / MixerFaderScale.maxAttenuationDB
        return thumbHeight / 2 + CGFloat(normalized) * max(trackHeight - thumbHeight, 1)
    }

    private func setValue(fromCenterY y: CGFloat, trackHeight: CGFloat, travel: CGFloat) {
        let clampedCenter = min(max(y, thumbHeight / 2), trackHeight - thumbHeight / 2)
        let normalized = Double((clampedCenter - thumbHeight / 2) / travel)
        value = MixerFaderScale.linearGain(forNormalizedPosition: normalized)
        onValueChanged()
    }
}

struct VerticalMixFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let faderHeight: CGFloat
    let onValueChanged: () -> Void

    var body: some View {
        MixerFaderColumn(
            value: $value,
            meterLevel: 0,
            height: faderHeight,
            onValueChanged: onValueChanged
        )
    }
}
