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
    private let meterGreen = Color(red: 0.22, green: 0.82, blue: 0.36)

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
                .fill(meterGreen)
                .frame(width: max(0, width - 8), height: meterBarHeight)

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(meterGreen)
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

    @State private var isDragging = false

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
                    .fill(AppColors.separator)
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
                        isDragging = true
                        setValue(fromCenterY: drag.location.y, trackHeight: trackHeight, travel: travel)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(width: thumbWidth)
    }

    private var faderThumb: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isDragging ? AppColors.accent.opacity(0.35) : AppColors.surfaceElevated)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDragging ? AppColors.accent : AppColors.separator, lineWidth: 1)
            }
            .overlay {
                Rectangle()
                    .fill(AppColors.textSecondary.opacity(0.55))
                    .frame(height: 1)
            }
            .frame(width: thumbWidth, height: thumbHeight)
    }

    private func scaleTicks(in trackHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(MixerFaderScale.attenuationMarks, id: \.self) { mark in
                let y = markY(forDB: Double(mark), in: trackHeight)
                Rectangle()
                    .fill(AppColors.textTertiary.opacity(mark == 0 ? 0.5 : 0.25))
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
                    .foregroundStyle(mark == 0 ? AppColors.textPrimary : AppColors.textTertiary)
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
                    .fill(AppColors.separator)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppColors.accent.opacity(0.85))
                    .frame(height: geometry.size.height * MixerFaderScale.meterFillFraction(forPeak: meterLevel))
            }
        }
        .frame(width: meterWidth, height: height)
    }

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
