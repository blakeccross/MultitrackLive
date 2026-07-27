import SwiftUI

struct TransportStatusReadout: View {
    let position: String
    let bpm: String
    let meter: String
    let key: String
    var onTapBPM: (() -> Void)? = nil
    var onTapMeter: (() -> Void)? = nil

    private static let width: CGFloat = 200
    private static let dividerWidth: CGFloat = 1
    private let minHeight: CGFloat = 40

    /// Near-black blue LCD face with soft cool light-blue readout text.
    private static let lcdFace = Color(red: 0.05, green: 0.07, blue: 0.11)
    private static let lcdText = Color(red: 0.72, green: 0.78, blue: 0.86)
    private static let lcdTextSecondary = Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.55)
    private static let lcdDivider = Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.16)

    private var containerShape: RoundedRectangle {
        // Continuous corners at half-height read as a horizontal squircle.
        RoundedRectangle(cornerRadius: minHeight / 3, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            readoutPrimaryColumn {
                Text(position)
                    .font(AppTypography.monoValue())
                    .foregroundStyle(Self.lcdText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }

            readoutDivider

            readoutCompactColumn {
                if let onTapBPM {
                    Button(action: onTapBPM) {
                        Text(bpm)
                            .font(AppTypography.monoValue())
                            .foregroundStyle(Self.lcdText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(bpm)
                        .font(AppTypography.monoValue())
                        .foregroundStyle(Self.lcdText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                }
            }

            readoutDivider

            readoutCompactColumn {
                if let onTapMeter {
                    Button(action: onTapMeter) {
                        meterKeyContent
                    }
                    .buttonStyle(.plain)
                } else {
                    meterKeyContent
                }
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: minHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            containerShape
                .fill(Self.lcdFace)
        }
    }

    private func readoutPrimaryColumn<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.vertical, AppSpacing.xs)
    }

    private func readoutCompactColumn<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
    }

    private var readoutDivider: some View {
        Rectangle()
            .fill(Self.lcdDivider)
            .frame(width: Self.dividerWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, AppSpacing.xs)
    }

    private var meterKeyContent: some View {
        VStack(spacing: AppSpacing.xxs) {
            Text(meter)
                .font(AppTypography.caption().monospaced().weight(.medium))
                .foregroundStyle(Self.lcdText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)

            Text(key)
                .font(AppTypography.caption().monospaced().weight(.medium))
                .foregroundStyle(Self.lcdTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
    }
}
