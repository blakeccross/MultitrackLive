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
                slotID: UUID(),
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

    func testPlaybackSectionsSilenceDeletedGapOnSourceLinearSong() {
        let markers = [
            ArrangementMarker(name: "INTRO", startSeconds: 0, sortOrder: 0),
        ]
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()
        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let layout = SongArrangementStore.buildLayoutSnapshot(
            slots: slots,
            clipTrims: [],
            removedClips: [],
            inputs: inputs
        )
        XCTAssertTrue(layout.rulerSections.usesSourceLinearTimeline)

        var regions = [
            ClipRegion(
                id: trackID,
                slotID: trackID,
                trackID: trackID,
                markerID: trackID,
                sourceStartSeconds: 0,
                sourceEndSeconds: 30,
                timelineStartSeconds: 0,
                timelineEndSeconds: 30
            ),
        ]
        _ = ClipRegionStore.deleteTimelineRange(
            slotID: trackID,
            trackID: trackID,
            rangeStart: 10,
            rangeEnd: 20,
            tempoChanges: [TempoChange(startMeasure: 1, bpm: 120)],
            timeSignatureChanges: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ],
            in: &regions
        )

        let playbackSections = SongArrangementStore.playbackTrackSections(
            for: trackID,
            trimStart: 0,
            trimEnd: 60,
            slots: slots,
            clipTrims: [],
            removedClips: [],
            clipRegions: regions,
            inputs: inputs,
            rulerSections: layout.rulerSections
        )

        XCTAssertEqual(playbackSections.count, 2)
        XCTAssertFalse(playbackSections.usesSourceLinearTimeline)

        let mapper = ArrangementTimelineMapper(
            sections: playbackSections,
            trimStart: 0,
            trimEnd: 60,
            usesArrangement: true
        )

        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 5) ?? -1, 5, accuracy: 0.001)
        XCTAssertNil(mapper.sourceSeconds(atMasterTimeline: 15))
        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 25) ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(
            mapper.regionRemainingSeconds(fromMasterTimeline: 15, bufferLimit: 10),
            5,
            accuracy: 0.001
        )
    }
}
