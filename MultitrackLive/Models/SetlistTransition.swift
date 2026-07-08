import Foundation
import SwiftUI

enum SetlistTransition: String, CaseIterable, Identifiable {
    case `continue`
    case stop
    case overlap

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
            return "arrow.triangle.merge"
        }
    }

    var badgeColor: Color {
        switch self {
        case .continue:
            return AppColors.accent
        case .stop:
            return AppColors.muteActive
        case .overlap:
            return Color.cyan
        }
    }

    var requiresOverlapConfig: Bool {
        self == .overlap
    }
}

struct SetlistTransitionBadge: View {
    let transition: SetlistTransition
    var size: CGFloat = 28
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                badgeContent
            }
            .buttonStyle(.plain)
        } else {
            badgeContent
        }
    }

    private var badgeContent: some View {
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
