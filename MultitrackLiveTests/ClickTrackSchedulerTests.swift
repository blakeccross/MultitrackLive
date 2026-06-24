import XCTest
@testable import MultitrackLive

final class ClickTrackSchedulerTests: XCTestCase {
    func testFourFourAt120BPMSchedulesQuarterNoteClicksInWindow() {
        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let clicks = ClickTrackScheduler.scheduledClicks(
            from: 0,
            to: 2,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            subdivision: .quarter
        )

        XCTAssertEqual(clicks.count, 4)
        XCTAssertEqual(clicks[0].time, 0, accuracy: 0.001)
        XCTAssertTrue(clicks[0].isAccent)
        XCTAssertEqual(clicks[1].time, 0.5, accuracy: 0.001)
        XCTAssertFalse(clicks[1].isAccent)
        XCTAssertEqual(clicks[2].time, 1.0, accuracy: 0.001)
        XCTAssertEqual(clicks[3].time, 1.5, accuracy: 0.001)
    }

    func testEighthNoteSubdivisionDoublesClickDensity() {
        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let clicks = ClickTrackScheduler.scheduledClicks(
            from: 0,
            to: 1,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            subdivision: .eighth
        )

        XCTAssertEqual(clicks.count, 4)
        XCTAssertEqual(clicks[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(clicks[1].time, 0.25, accuracy: 0.001)
        XCTAssertEqual(clicks[2].time, 0.5, accuracy: 0.001)
        XCTAssertEqual(clicks[3].time, 0.75, accuracy: 0.001)
    }

    func testWindowStartsMidMeasure() {
        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let clicks = ClickTrackScheduler.scheduledClicks(
            from: 0.75,
            to: 1.51,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            subdivision: .quarter
        )

        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].time, 1.0, accuracy: 0.001)
        XCTAssertEqual(clicks[1].time, 1.5, accuracy: 0.001)
    }
}
