import XCTest
@testable import MultitrackLive

final class SongArrangementLayoutTests: XCTestCase {
    func testPackedRulerSectionsStartAtTimelineZero() {
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
        XCTAssertEqual(sections[0].timelineStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sections[0].sourceStartSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(sections[0].timelineEndSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(sections[1].timelineStartSeconds, 60, accuracy: 0.001)
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
        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers[0].name, "Start")
        XCTAssertEqual(markers[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(markers[1].startSeconds, 16, accuracy: 0.001)
        XCTAssertEqual(markers[2].startSeconds, 48, accuracy: 0.001)
    }

    func testAbletonImportPrependsStartSectionForPackedTimeline() {
        let result = AbletonProjectImporter.ImportResult(
            bpm: 120,
            sections: [
                (name: "Verse", startSeconds: 4),
            ],
            timeSignatures: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ]
        )
        let markers = AbletonProjectImporter.makeMarkers(from: result)
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()

        let sections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].name, "Start")
        XCTAssertEqual(sections[0].timelineStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sections[0].sourceStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sections[0].timelineEndSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(sections[1].name, "Verse")
        XCTAssertEqual(sections[1].timelineStartSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(sections[1].sourceStartSeconds, 4, accuracy: 0.001)
    }

    func testPackedRulerSectionsShowPerMarkerTrackLanes() {
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
    }

    func testPlaybackSectionsSilenceDeletedGapOnPackedLayout() {
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
        XCTAssertEqual(layout.rulerSections[0].timelineStartSeconds, 0, accuracy: 0.001)

        var regions = [
            ClipRegion(
                id: trackID,
                slotID: slots[0].id,
                trackID: trackID,
                markerID: markers[0].id,
                sourceStartSeconds: 0,
                sourceEndSeconds: 30,
                timelineStartSeconds: 0,
                timelineEndSeconds: 30
            ),
        ]
        _ = ClipRegionStore.deleteTimelineRange(
            slotID: slots[0].id,
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
            inputs: inputs
        )

        XCTAssertEqual(playbackSections.count, 2)

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

    func testPlaybackAfterRippleDeleteFromMeasureOne() {
        var markers = [
            ArrangementMarker(name: "Intro", startSeconds: 0, sortOrder: 0),
            ArrangementMarker(name: "Verse", startSeconds: 40, sortOrder: 1),
        ]
        var slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()
        var clipRegions: [ClipRegion] = []
        var loopSlotIDs: Set<UUID> = []
        var tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        var timeSignatureChanges = [
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
        ]
        var midiEvents: [MIDIEvent] = []
        var clipGaps: [ArrangementClipGap] = []

        let tracks = [
            TimelineRippleStore.Track(id: trackID, trimStart: 0, trimEnd: 60, sourceDuration: 60),
        ]

        // Delete measures 1-2 -> removes 4 seconds from the start at 120 BPM in 4/4.
        _ = TimelineRippleStore.rippleDeleteMeasures(
            startMeasure: 1,
            endMeasure: 3,
            markers: &markers,
            slots: &slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: &clipGaps,
            clipRegions: &clipRegions,
            loopSlotIDs: &loopSlotIDs,
            tempoChanges: &tempoChanges,
            timeSignatureChanges: &timeSignatureChanges,
            midiEvents: &midiEvents,
            tracks: tracks,
            defaultBPM: 120,
            defaultNumerator: 4,
            defaultDenominator: 4
        )

        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let rulerSections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        XCTAssertEqual(rulerSections[0].timelineStartSeconds, 0, accuracy: 0.001)

        let playbackSections = SongArrangementStore.playbackTrackSections(
            for: trackID,
            trimStart: 0,
            trimEnd: 60,
            slots: slots,
            clipTrims: [],
            removedClips: [],
            clipRegions: clipRegions,
            inputs: inputs
        )

        XCTAssertFalse(playbackSections.isEmpty)

        let mapper = ArrangementTimelineMapper(
            sections: playbackSections,
            trimStart: 0,
            trimEnd: 60,
            usesArrangement: true
        )

        XCTAssertEqual(mapper.sourceSeconds(atMasterTimeline: 0) ?? -1, 4, accuracy: 0.001)
        XCTAssertTrue(mapper.hasArrangementMapping)
    }

    func testWaveformPeakSectionsUsePlaybackLayoutAfterRipple() {
        var markers = [
            ArrangementMarker(name: "Intro", startSeconds: 0, sortOrder: 0),
            ArrangementMarker(name: "Verse", startSeconds: 40, sortOrder: 1),
        ]
        var slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()
        var clipRegions: [ClipRegion] = []
        var loopSlotIDs: Set<UUID> = []
        var tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        var timeSignatureChanges = [
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
        ]
        var midiEvents: [MIDIEvent] = []
        var clipGaps: [ArrangementClipGap] = []

        _ = TimelineRippleStore.rippleDeleteMeasures(
            startMeasure: 1,
            endMeasure: 3,
            markers: &markers,
            slots: &slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: &clipGaps,
            clipRegions: &clipRegions,
            loopSlotIDs: &loopSlotIDs,
            tempoChanges: &tempoChanges,
            timeSignatureChanges: &timeSignatureChanges,
            midiEvents: &midiEvents,
            tracks: [
                TimelineRippleStore.Track(id: trackID, trimStart: 0, trimEnd: 60, sourceDuration: 60),
            ],
            defaultBPM: 120,
            defaultNumerator: 4,
            defaultDenominator: 4
        )

        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let rulerSections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let playbackLayout = SongArrangementStore.playbackLayoutSnapshot(
            slots: slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            tracks: [(trackID, 0, 60)],
            inputs: inputs
        )

        let peakSections = PlaybackCoordinator.waveformPeakSections(
            playbackLayout: playbackLayout,
            rulerSections: rulerSections
        )

        XCTAssertEqual(
            peakSections.map(\.timelineStartSeconds),
            playbackLayout.trackSections[trackID]?.map(\.timelineStartSeconds) ?? []
        )
    }

    func testWaveformPeakSectionsUsePlaybackLayoutForDefaultImport() {
        let markers = [
            ArrangementMarker(name: "Intro", startSeconds: 0, sortOrder: 0),
            ArrangementMarker(name: "Verse", startSeconds: 40, sortOrder: 1),
        ]
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()
        let inputs = SongArrangementStore.makeLayoutInputs(
            markers: markers,
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let rulerSections = SongArrangementStore.rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: [],
            trackIDs: [trackID],
            sourceDurationForTrack: { _ in 60 }
        )
        let playbackLayout = SongArrangementStore.playbackLayoutSnapshot(
            slots: slots,
            clipTrims: [],
            removedClips: [],
            clipGaps: [],
            clipRegions: [],
            tracks: [(trackID, 0, 60)],
            inputs: inputs
        )

        let peakSections = PlaybackCoordinator.waveformPeakSections(
            playbackLayout: playbackLayout,
            rulerSections: rulerSections
        )

        XCTAssertEqual(
            peakSections.map(\.timelineStartSeconds),
            playbackLayout.trackSections[trackID]?.map(\.timelineStartSeconds) ?? []
        )
        XCTAssertEqual(peakSections.first?.timelineStartSeconds ?? -1, 0, accuracy: 0.001)
    }
}
