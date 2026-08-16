import SwiftUI

enum AppAnimation {
    static let springSnappy = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let springSmooth = Animation.spring(response: 0.45, dampingFraction: 0.86)
    static let fadeQuick = Animation.easeInOut(duration: 0.2)
}
