import XCTest
@testable import MultitrackLive

final class AudioPlaybackTransportTests: XCTestCase {
    func testMappedTimelineAppliesPendingTransitionAtCorrectPoint() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)

        // Before transition.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 2.5), 2.5, accuracy: 0.0000001)

        // Exactly at transition start: jumps to targetOffset.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 3.0), 2.0, accuracy: 0.0000001)

        // After transition: continues forward from the target offset.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 4.0), 3.0, accuracy: 0.0000001)
    }

    func testMappedTimelineClampsToDuration() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)

        XCTAssertEqual(transport.mappedTimeline(fromLinear: 12.0), 10.0, accuracy: 0.0000001)
    }

    func testCancelScheduledTransitionClearsMapping() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)
        transport.cancelScheduledTransition()

        // Without a pending transition, mapping should return the raw linear value.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 4.0), 4.0, accuracy: 0.0000001)
    }
}

