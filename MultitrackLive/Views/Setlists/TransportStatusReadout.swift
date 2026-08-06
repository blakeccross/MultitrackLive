import SwiftUI

struct TransportStatusReadout: View {
    let position: String

    private let minWidth: CGFloat = 120
    private let minHeight: CGFloat = 40

    var body: some View {
        Text(position)
            .font(AppTypography.monoValue())
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .fixedSize(horizontal: true, vertical: false)
    }
}
