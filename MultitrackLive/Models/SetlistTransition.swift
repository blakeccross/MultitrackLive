import Foundation
import SwiftUI

enum SetlistTransition: String, CaseIterable, Identifiable {
    case `continue`
    case stop
    case overlap

    /// Default lead time before the outgoing song ends when the next song begins.
    static let overlapLeadTime: TimeInterval = 4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continue:
            return "Continue"
        case .stop:
            return "Stop"
        case .overlap:
            return "Overlap"
        }
    }

    var systemImage: String {
        switch self {
        case .continue:
            return "arrow.right"
        case .stop:
            return "stop"
        case .overlap:
            return "square.2.layers.3d"
        }
    }

    var badgeColor: Color {
        switch self {
        case .continue:
            return AppColors.accent
        case .stop:
            return AppColors.muteActive
        case .overlap:
            return AppColors.accent.opacity(0.7)
        }
    }
}

struct SetlistTransitionBadge: View {
    let transition: SetlistTransition
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: transition.systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(AppColors.textPrimary)
            .frame(width: size, height: size)
            .background(AppColors.surfaceElevated)
            .overlay {
                Circle()
                    .stroke(transition.badgeColor, lineWidth: 1.5)
            }
            .clipShape(Circle())
    }
}
