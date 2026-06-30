import SwiftUI

struct TransportStatusReadout: View {
    let position: String
    let bpm: String
    let meter: String
    let key: String

    private let minHeight: CGFloat = 40

    private var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: minHeight * 0.25, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            readoutSegment {
                Text(position)
                    .appMonoValue()
            }

            readoutDivider

            readoutSegment {
                Text(bpm)
                    .appMonoValue()
            }

            readoutDivider

            readoutSegment(alignment: .leading) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(meter)
                        .font(AppTypography.caption().monospacedDigit().weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    Text(key)
                        .font(AppTypography.caption().weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: minHeight)
        .background(AppColors.surface, in: containerShape)
        .overlay {
            containerShape
                .strokeBorder(AppColors.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func readoutSegment<Content: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxHeight: .infinity, alignment: alignment)
    }

    private var readoutDivider: some View {
        Rectangle()
            .fill(AppColors.separator.opacity(0.75))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.vertical, AppSpacing.xs)
    }
}
