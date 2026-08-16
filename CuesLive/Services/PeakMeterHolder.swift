import Foundation
import os

final class PeakMeterHolder: @unchecked Sendable {
    private var peak: Float = 0
    private let lock = OSAllocatedUnfairLock()

    func report(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        lock.withLock {
            peak = max(peak, value)
        }
    }

    func consume(decay: Float = 0.55) -> Float {
        lock.withLock {
            let current = peak
            peak *= decay
            return current
        }
    }

    func reset() {
        lock.withLock {
            peak = 0
        }
    }
}
