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

    /// Muted steel-blue LCD face for an analogue hardware feel.
    private static let lcdFace = Color(red: 0.56, green: 0.63, blue: 0.68)
    private static let lcdText = Color(red: 0.10, green: 0.12, blue: 0.15)
    private static let lcdTextSecondary = Color(red: 0.10, green: 0.12, blue: 0.15).opacity(0.65)
    private static let lcdDivider = Color(red: 0.10, green: 0.12, blue: 0.15).opacity(0.28)

    private var cornerRadius: CGFloat {
        max(4, minHeight * 0.14)
    }

    private var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
            ZStack {
                containerShape
                    .fill(Color.black.opacity(0.55))
                    .offset(y: 1)

                containerShape
                    .fill(Self.lcdFace)

                containerShape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.45),
                                Color.white.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .padding(0.5)

                containerShape
                    .stroke(Color.black.opacity(0.85), lineWidth: 1)
            }
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
