import Foundation
import SwiftUI

enum SetlistTransition: String, CaseIterable, Identifiable {
    case `continue`
    case stop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continue:
            return "Continue"
        case .stop:
            return "Stop"
        }
    }

    var systemImage: String {
        switch self {
        case .continue:
            return "arrow.right"
        case .stop:
            return "stop.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .continue:
            return .accentColor
        case .stop:
            return .orange
        }
    }
}

struct SetlistTransitionBadge: View {
    let transition: SetlistTransition
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: transition.systemImage)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(transition.badgeColor)
            .clipShape(Circle())
    }
}
