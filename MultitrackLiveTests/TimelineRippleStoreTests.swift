import XCTest
@testable import MultitrackLive

/// Uses 120 BPM in 4/4 throughout, so one measure spans exactly 2 seconds and
/// `timeAtStartOfMeasure(m) == (m - 1) * 2`.
final class TimelineRippleStoreTests: XCTestCase {
    private func defaultTempo() -> [TempoChange] {
        [TempoChange(startMeasure: 1, bpm: 120)]
    }

    private func defaultTimeSignature() -> [TimeSignatureChange] {
        [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0)]
    }

    private func region(
        trackID: UUID,
        source: ClosedRange<TimeInterval>,
        timeline: ClosedRange<TimeInterval>,
        id: UUID = UUID()
    ) -> ClipRegion {
        ClipRegion(
            id: id,
            slotID: trackID,
            trackID: trackID,
            markerID: trackID,
            sourceStartSeconds: source.lowerBound,
            sourceEndSeconds: source.upperBound,
            timelineStartSeconds: timeline.lowerBound,
            timelineEndSeconds: timeline.upperBound
        )
    }

    @discardableResult
    private func ripple(
        start: Int,
        end: Int,
        markers: inout [ArrangementMarker],
        slots: inout [ArrangementSlot],
        clipRegions: inout [ClipRegion],
        loopSlotIDs: inout Set<UUID>,
        tempoChanges: inout [TempoChange],
        timeSignatureChanges: inout [TimeSignatureChange],
        midiEvents: inout [MIDIEvent],
        tracks: [TimelineRippleStore.Track] = []
    ) -> TimelineRippleStore.Result {
        var clipGaps: [ArrangementClipGap] = []
        return TimelineRippleStore.rippleDeleteMeasures(
            startMeasure: start,
            endMeasure: end,
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
    }

    func testRegionAfterWindowShiftsLeft() {
        let trackID = UUID()
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions = [region(trackID: trackID, source: 10...20, timeline: 10...20)]

        // Delete measures 3-4 -> window [4, 8), removedDuration 4.
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].timelineStartSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(regions[0].timelineEndSeconds, 16, accuracy: 0.001)
        // Source is unchanged by the shift.
        XCTAssertEqual(regions[0].sourceStartSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(regions[0].sourceEndSeconds, 20, accuracy: 0.001)
    }

    func testRegionSpanningWindowSplitsAndClosesGap() {
        let trackID = UUID()
        let regionID = UUID()
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions = [region(trackID: trackID, source: 0...30, timeline: 0...30, id: regionID)]

        // Delete measures 6-10 -> window [10, 20), removedDuration 10.
        ripple(
            start: 6, end: 11,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        XCTAssertEqual(regions.count, 2)
        let sorted = regions.sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        XCTAssertEqual(sorted[0].timelineStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sorted[0].timelineEndSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(sorted[0].id, regionID, "Left piece keeps the original region id")
        XCTAssertEqual(sorted[1].timelineStartSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(sorted[1].timelineEndSeconds, 20, accuracy: 0.001)
        // Right piece kept its source content [20, 30].
        XCTAssertEqual(sorted[1].sourceStartSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(sorted[1].sourceEndSeconds, 30, accuracy: 0.001)
        XCTAssertNotEqual(sorted[1].id, regionID, "Right piece gets a fresh id")
    }

    func testRegionFullyInsideWindowIsRemoved() {
        let trackID = UUID()
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions = [region(trackID: trackID, source: 5...7, timeline: 5...7)]

        // Delete measures 3-4 -> window [4, 8).
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        XCTAssertTrue(regions.isEmpty)
    }

    func testTempoChangesRenumberByMeasure() {
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = [
            TempoChange(startMeasure: 1, bpm: 120),
            TempoChange(startMeasure: 7, bpm: 140),
        ]
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions: [ClipRegion] = []

        // Delete measures 3-4 -> removedMeasures 2.
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        let sorted = tempo.sortedByMeasure
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].startMeasure, 1)
        XCTAssertEqual(sorted[0].bpm, 120, accuracy: 0.001)
        XCTAssertEqual(sorted[1].startMeasure, 5)
        XCTAssertEqual(sorted[1].bpm, 140, accuracy: 0.001)
    }

    func testDeletingFromMeasureOnePromotesLaterTempo() {
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = [
            TempoChange(startMeasure: 1, bpm: 120),
            TempoChange(startMeasure: 3, bpm: 150),
        ]
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions: [ClipRegion] = []

        // Delete measures 1-2 -> the tempo active at measure 3 becomes measure 1.
        ripple(
            start: 1, end: 3,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        let sorted = tempo.sortedByMeasure
        XCTAssertEqual(sorted.first?.startMeasure, 1)
        XCTAssertEqual(sorted.first?.bpm ?? 0, 150, accuracy: 0.001)
    }

    func testTimeSignatureChangesRenumberByMeasure() {
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = [
            TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            TimeSignatureChange(numerator: 3, denominator: 4, startMeasure: 9, sortOrder: 1),
        ]
        var midi: [MIDIEvent] = []
        var regions: [ClipRegion] = []

        // Delete measures 3-4 -> removedMeasures 2.
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        let sorted = timeSig.sortedByMeasure
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[1].startMeasure, 7)
        XCTAssertEqual(sorted[1].numerator, 3)
        XCTAssertEqual(sorted[1].denominator, 4)
    }

    func testMarkersRemovedAndShifted() {
        var markers = [
            ArrangementMarker(name: "Intro", startSeconds: 0, sortOrder: 0),
            ArrangementMarker(name: "Verse", startSeconds: 5, sortOrder: 1),
            ArrangementMarker(name: "Chorus", startSeconds: 10, sortOrder: 2),
        ]
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions: [ClipRegion] = []

        // Delete measures 3-4 -> window [4, 8), removedDuration 4.
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        let sorted = markers.sortedByTime
        XCTAssertEqual(sorted.count, 2, "Marker inside the deleted window is removed")
        XCTAssertEqual(sorted[0].name, "Intro")
        XCTAssertEqual(sorted[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sorted[1].name, "Chorus")
        XCTAssertEqual(sorted[1].startSeconds, 6, accuracy: 0.001)
    }

    func testMidiEventsRemovedAndShifted() {
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        let trackID = UUID()
        var midi = [
            MIDIEvent(trackID: trackID, timelineSeconds: 2, commandID: UUID()),
            MIDIEvent(trackID: trackID, timelineSeconds: 5, commandID: UUID()),
            MIDIEvent(trackID: trackID, timelineSeconds: 10, commandID: UUID()),
        ]
        var regions: [ClipRegion] = []

        // Delete measures 3-4 -> window [4, 8), removedDuration 4.
        ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi
        )

        let times = midi.map(\.timelineSeconds).sorted()
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times[0], 2, accuracy: 0.001)
        XCTAssertEqual(times[1], 6, accuracy: 0.001)
    }

    func testMaterializesTrackWithoutRegionsAndReportsEmptied() {
        let coveredTrack = UUID()
        let clearedTrack = UUID()
        var markers: [ArrangementMarker] = []
        var slots: [ArrangementSlot] = []
        var loopSlotIDs: Set<UUID> = []
        var tempo = defaultTempo()
        var timeSig = defaultTimeSignature()
        var midi: [MIDIEvent] = []
        var regions: [ClipRegion] = []

        let tracks = [
            TimelineRippleStore.Track(id: coveredTrack, trimStart: 0, trimEnd: 30, sourceDuration: 30),
            TimelineRippleStore.Track(id: clearedTrack, trimStart: 4, trimEnd: 8, sourceDuration: 30),
        ]

        // Delete measures 3-4 -> window [4, 8).
        let result = ripple(
            start: 3, end: 5,
            markers: &markers, slots: &slots, clipRegions: &regions,
            loopSlotIDs: &loopSlotIDs, tempoChanges: &tempo,
            timeSignatureChanges: &timeSig, midiEvents: &midi,
            tracks: tracks
        )

        XCTAssertTrue(result.emptiedTrackIDs.contains(clearedTrack))
        XCTAssertFalse(result.emptiedTrackIDs.contains(coveredTrack))
        XCTAssertTrue(regions.contains { $0.trackID == coveredTrack })
        XCTAssertFalse(regions.contains { $0.trackID == clearedTrack })
    }
}
