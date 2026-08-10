import XCTest
@testable import MultitrackLive

final class OutputRoutingManagerTests: XCTestCase {
    func testStereoPairChannelMapPlacesSourceChannelsOnHardwarePair() {
        let map = OutputRoutingManager.channelMap(
            for: .stereoPair(startChannel: 3),
            outputChannelCount: 8
        )

        XCTAssertEqual(map.map(\.intValue), [-1, -1, 0, 1, -1, -1, -1, -1])
    }

    func testMonoChannelMapPlacesLeftOnSelectedHardwareChannel() {
        let map = OutputRoutingManager.channelMap(
            for: .mono(channel: 5),
            outputChannelCount: 8
        )

        XCTAssertEqual(map.map(\.intValue), [-1, -1, -1, -1, 0, -1, -1, -1])
    }

    func testOutOfRangeDestinationFallsBackToFirstStereoPair() {
        let map = OutputRoutingManager.channelMap(
            for: .stereoPair(startChannel: 9),
            outputChannelCount: 8
        )

        XCTAssertEqual(map.map(\.intValue), [0, 1, -1, -1, -1, -1, -1, -1])
    }

    func testDefaultStereoMap() {
        XCTAssertEqual(
            OutputRoutingManager.defaultStereoMap(4).map(\.intValue),
            [0, 1, -1, -1]
        )
    }
}
