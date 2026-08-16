import XCTest
@testable import CuesLive

final class CueTrackSchedulerTests: XCTestCase {
    func testSkipsSectionAtTimelineZero() {
        let tempo = [TempoChange(startMeasure: 1, bpm: 120)]
        let signatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let announcements = CueTrackScheduler.scheduledAnnouncements(
            sections: [
                (name: "Intro", startSeconds: 0),
                (name: "Verse", startSeconds: 8),
            ],
            tempoChanges: tempo,
            timeSignatureChanges: signatures
        )

        XCTAssertEqual(announcements.count, 1)
        XCTAssertEqual(announcements[0].name, "Verse")
        XCTAssertEqual(announcements[0].boundaryTime, 8, accuracy: 0.001)
        // One measure at 120 BPM / 4/4 is 2 seconds.
        XCTAssertEqual(announcements[0].announceTime, 6, accuracy: 0.001)
    }

    func testClampsAnnounceTimeToZeroWhenLeadExceedsBoundary() {
        let tempo = [TempoChange(startMeasure: 1, bpm: 60)]
        let signatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let announcements = CueTrackScheduler.scheduledAnnouncements(
            sections: [
                (name: "Verse", startSeconds: 2),
            ],
            tempoChanges: tempo,
            timeSignatureChanges: signatures
        )

        XCTAssertEqual(announcements.count, 1)
        // One measure at 60 BPM / 4/4 is 4 seconds; clamp to song start.
        XCTAssertEqual(announcements[0].announceTime, 0, accuracy: 0.001)
        XCTAssertEqual(announcements[0].boundaryTime, 2, accuracy: 0.001)
    }

    func testIgnoresBlankSectionNames() {
        let tempo = [TempoChange(startMeasure: 1, bpm: 120)]
        let signatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let announcements = CueTrackScheduler.scheduledAnnouncements(
            sections: [
                (name: "   ", startSeconds: 4),
                (name: "Chorus", startSeconds: 8),
            ],
            tempoChanges: tempo,
            timeSignatureChanges: signatures
        )

        XCTAssertEqual(announcements.map(\.name), ["Chorus"])
    }
}
