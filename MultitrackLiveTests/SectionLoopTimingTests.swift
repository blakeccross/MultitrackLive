import XCTest
@testable import MultitrackLive

final class SectionLoopTimingTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testHasReachedBoundaryMatchesEngineEndThreshold() {
        let sectionEnd = 16.0
        let justBeforeEngineStop = sectionEnd - (1.0 / sampleRate)

        XCTAssertTrue(
            SectionLoopTiming.hasReachedBoundary(
                time: justBeforeEngineStop,
                sectionEnd: sectionEnd,
                sampleRate: sampleRate
            )
        )
        XCTAssertFalse(
            SectionLoopTiming.hasReachedBoundary(
                time: sectionEnd - (2.0 / sampleRate),
                sectionEnd: sectionEnd,
                sampleRate: sampleRate
            )
        )
    }

    func testSectionEndsAtSongEndForSingleSectionClickSong() {
        XCTAssertTrue(
            SectionLoopTiming.sectionEndsAtSongEnd(
                sectionEnd: 16.0,
                songDuration: 16.0,
                sampleRate: sampleRate
            )
        )
        XCTAssertFalse(
            SectionLoopTiming.sectionEndsAtSongEnd(
                sectionEnd: 8.0,
                songDuration: 16.0,
                sampleRate: sampleRate
            )
        )
    }

    func testSectionEndsAtSongEndAllowsOneSampleTolerance() {
        let duration = 16.0
        let sectionEnd = duration - (0.5 / sampleRate)

        XCTAssertTrue(
            SectionLoopTiming.sectionEndsAtSongEnd(
                sectionEnd: sectionEnd,
                songDuration: duration,
                sampleRate: sampleRate
            )
        )
    }
}
