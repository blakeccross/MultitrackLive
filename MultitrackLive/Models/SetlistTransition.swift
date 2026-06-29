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
            return "stop.fill"
        case .overlap:
            return "square.2.layers.3d"
        }
    }

    var badgeColor: Color {
        switch self {
        case .continue:
            return .accentColor
        case .stop:
            return .orange
        case .overlap:
            return .purple
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
