import XCTest
@testable import MultitrackLive

final class OverlapTransitionConfigTests: XCTestCase {
    func testInitClampsStartOffsetSecondsToNonNegative() {
        let config = OverlapTransitionConfig(startOffsetSeconds: -1)
        XCTAssertEqual(config.startOffsetSeconds, 0, accuracy: 0.000001)
    }

    func testIsValidRequiresPositiveOffset() {
        XCTAssertFalse(OverlapTransitionConfig(startOffsetSeconds: 0).isValid)
        XCTAssertTrue(OverlapTransitionConfig(startOffsetSeconds: 0.0001).isValid)
    }
}

