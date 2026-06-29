import SwiftUI

enum AppTypography {
    static func largeTitle() -> Font {
        .title.bold()
    }

    static func title() -> Font {
        .title3.weight(.semibold)
    }

    static func body() -> Font {
        .body
    }

    static func caption() -> Font {
        .caption
    }

    static func monoValue() -> Font {
        .title2.monospacedDigit().weight(.medium)
    }
}

extension View {
    func appLargeTitle() -> some View {
        font(AppTypography.largeTitle())
            .foregroundStyle(AppColors.textPrimary)
    }

    func appTitle() -> some View {
        font(AppTypography.title())
            .foregroundStyle(AppColors.textPrimary)
    }

    func appBodyText() -> some View {
        font(AppTypography.body())
            .foregroundStyle(AppColors.textPrimary)
    }

    func appCaptionText() -> some View {
        font(AppTypography.caption())
            .foregroundStyle(AppColors.textSecondary)
    }

    func appMonoValue() -> some View {
        font(AppTypography.monoValue())
            .foregroundStyle(AppColors.textPrimary)
            .minimumScaleFactor(0.8)
            .lineLimit(1)
    }
}
