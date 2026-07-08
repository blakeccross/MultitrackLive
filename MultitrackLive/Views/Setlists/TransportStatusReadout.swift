import SwiftUI

struct TransportStatusReadout: View {
    let position: String
    let bpm: String
    let meter: String
    let key: String
    var onTapBPM: (() -> Void)? = nil

    private static let width: CGFloat = 200
    private static let dividerWidth: CGFloat = 1
    private let minHeight: CGFloat = 40

    private var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: minHeight * 0.25, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            readoutPrimaryColumn {
                Text(position)
                    .appMonoValue()
                    .multilineTextAlignment(.center)
            }

            readoutDivider

            readoutCompactColumn {
                if let onTapBPM {
                    Button(action: onTapBPM) {
                        Text(bpm)
                            .appMonoValue()
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(bpm)
                        .appMonoValue()
                        .multilineTextAlignment(.center)
                }
            }

            readoutDivider

            readoutCompactColumn {
                VStack(spacing: AppSpacing.xxs) {
                    Text(meter)
                        .font(AppTypography.caption().monospacedDigit().weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)

                    Text(key)
                        .font(AppTypography.caption().weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: Self.width)
        .frame(minHeight: minHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(AppColors.surface, in: containerShape)
        .overlay {
            containerShape
                .strokeBorder(AppColors.separator.opacity(0.55), lineWidth: 0.5)
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
            .fill(AppColors.separator.opacity(0.75))
            .frame(width: Self.dividerWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, AppSpacing.xs)
    }
}
