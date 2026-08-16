import XCTest
@testable import CuesLive

final class TimecodeStartCalculatorTests: XCTestCase {
    func testResetPerSongAlwaysUsesStartingHour() {
        let start = TimecodeStartCalculator.startTimecode(
            mode: .resetPerSong,
            startingHour: 1,
            songIndex: 3,
            priorSongDurations: [120, 180, 90],
            frameRate: .fps30
        )
        XCTAssertEqual(start, TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 0))
    }

    func testPerSongHourIncrementsHourByIndex() {
        let start = TimecodeStartCalculator.startTimecode(
            mode: .perSongHour,
            startingHour: 1,
            songIndex: 2,
            priorSongDurations: [60, 60],
            frameRate: .fps30
        )
        XCTAssertEqual(start, TimecodeValue(hours: 3, minutes: 0, seconds: 0, frames: 0))
    }

    func testContinuousShowTimeAddsPriorDurations() {
        let start = TimecodeStartCalculator.startTimecode(
            mode: .continuousShowTime,
            startingHour: 1,
            songIndex: 2,
            priorSongDurations: [65, 125],
            frameRate: .fps30
        )
        // 01:00:00:00 + 190s = 01:03:10:00
        XCTAssertEqual(start, TimecodeValue(hours: 1, minutes: 3, seconds: 10, frames: 0))
    }

    func testStartingHourIsClamped() {
        let start = TimecodeStartCalculator.startTimecode(
            mode: .resetPerSong,
            startingHour: 40,
            songIndex: 0,
            priorSongDurations: [],
            frameRate: .fps30
        )
        XCTAssertEqual(start.hours, 23)
    }
}
