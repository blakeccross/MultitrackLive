import XCTest
@testable import MultitrackLive

final class SongArrangementLayoutTests: XCTestCase {
    func testRulerSectionsPreserveMarkerSourceOffsetWhenSlotsMatchMarkerOrder() {
        let markers = [
            ArrangementMarker(name: "Intro", startSeconds: 30, sortOrder: 0),
            ArrangementMarker(name: "Verse", startSeconds: 90, sortOrder: 1),
        ]
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()

        let sections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 180 }
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].timelineStartSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(sections[0].sourceStartSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(sections[1].timelineStartSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(sections[1].sourceStartSeconds, 90, accuracy: 0.001)
    }

    func testAbletonImportPreservesNonZeroFirstMarker() throws {
        let result = AbletonProjectImporter.ImportResult(
            bpm: 120,
            sections: [
                (name: "Intro", startSeconds: 16),
                (name: "Verse", startSeconds: 48),
            ],
            timeSignatures: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ]
        )

        let markers = AbletonProjectImporter.makeMarkers(from: result)
        XCTAssertEqual(markers[0].startSeconds, 16, accuracy: 0.001)
        XCTAssertEqual(markers[1].startSeconds, 48, accuracy: 0.001)
    }

    func testSourceLinearTimelineMapperPlaysAudioBeforeFirstMarker() {
        let sections = [
            ArrangementDisplaySection(
                id: UUID(),
                markerID: UUID(),
                name: "Intro",
                sourceStartSeconds: 8,
                sourceEndSeconds: 15,
                timelineStartSeconds: 8,
                timelineEndSeconds: 15,
                columnStartSeconds: 8,
                columnEndSeconds: 15
            ),
        ]
        XCTAssertTrue(sections.usesSourceLinearTimeline)

        let mapper = ArrangementTimelineMapper(
            sections: sections,
            trimStart: 0,
            trimEnd: 60,
            usesArrangement: true
        )

        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 0) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 4) ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 10) ?? -1, 10, accuracy: 0.001)
        XCTAssertFalse(mapper.hasArrangementMapping)
    }

    func testSourceLinearRulerSectionsDoNotRequireTrackSegments() {
        let markers = [
            ArrangementMarker(name: "INTRO", startSeconds: 8, sortOrder: 0),
            ArrangementMarker(name: "V1", startSeconds: 16, sortOrder: 1),
        ]
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()

        let rulerSections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 120 }
        )
        XCTAssertTrue(rulerSections.usesSourceLinearTimeline)

        let trackSections = SongArrangementStore.trackDisplaySections(
            for: trackID,
            slots: slots,
            markers: markers,
            clipTrims: [],
            removedClips: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 120 }
        )
        XCTAssertFalse(trackSections.isEmpty)

        // Editor omits per-marker track segments when the ruler uses source-linear layout.
        let laneSections = rulerSections.usesSourceLinearTimeline ? [] : trackSections
        XCTAssertTrue(laneSections.isEmpty)
    }
}
