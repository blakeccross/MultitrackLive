import XCTest
@testable import MultitrackLive

final class ClipRegionStoreTests: XCTestCase {
    func testSplitRegionCreatesTwoTouchingRegions() {
        let slotID = UUID()
        let trackID = UUID()
        let markerID = UUID()
        var regions = [
            ClipRegion(
                id: slotID,
                slotID: slotID,
                trackID: trackID,
                markerID: markerID,
                sourceStartSeconds: 0,
                sourceEndSeconds: 20,
                timelineStartSeconds: 10,
                timelineEndSeconds: 30
            ),
        ]

        let rightID = ClipRegionStore.splitRegion(
            regionID: slotID,
            at: 20,
            tempoChanges: [TempoChange(startMeasure: 1, bpm: 120)],
            timeSignatureChanges: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ],
            in: &regions
        )

        XCTAssertNotNil(rightID)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].timelineEndSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(regions[1].timelineStartSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(regions[0].sourceEndSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(regions[1].sourceStartSeconds, 10, accuracy: 0.001)
    }

    func testJoinAdjacentRegionsMergesBounds() {
        let slotID = UUID()
        let trackID = UUID()
        let markerID = UUID()
        let leftID = UUID()
        let rightID = UUID()
        var regions = [
            ClipRegion(
                id: leftID,
                slotID: slotID,
                trackID: trackID,
                markerID: markerID,
                sourceStartSeconds: 0,
                sourceEndSeconds: 10,
                timelineStartSeconds: 0,
                timelineEndSeconds: 10
            ),
            ClipRegion(
                id: rightID,
                slotID: slotID,
                trackID: trackID,
                markerID: markerID,
                sourceStartSeconds: 10,
                sourceEndSeconds: 20,
                timelineStartSeconds: 10,
                timelineEndSeconds: 20
            ),
        ]

        let mergedID = ClipRegionStore.joinRegions(firstID: leftID, secondID: rightID, in: &regions)

        XCTAssertEqual(mergedID, leftID)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].timelineStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(regions[0].timelineEndSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(regions[0].sourceStartSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(regions[0].sourceEndSeconds, 20, accuracy: 0.001)
    }

    func testMiddleDeleteLeavesTimelineGap() {
        let slotID = UUID()
        let trackID = UUID()
        let markerID = UUID()
        var regions = [
            ClipRegion(
                id: slotID,
                slotID: slotID,
                trackID: trackID,
                markerID: markerID,
                sourceStartSeconds: 0,
                sourceEndSeconds: 30,
                timelineStartSeconds: 0,
                timelineEndSeconds: 30
            ),
        ]

        _ = ClipRegionStore.deleteTimelineRange(
            slotID: slotID,
            trackID: trackID,
            rangeStart: 10,
            rangeEnd: 20,
            tempoChanges: [TempoChange(startMeasure: 1, bpm: 120)],
            timeSignatureChanges: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ],
            in: &regions
        )

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].timelineEndSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(regions[1].timelineStartSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(regions[1].timelineEndSeconds, 30, accuracy: 0.001)
    }

    func testMigrateClipGapsToRegionsPreservesSplitLayout() {
        let markers = [
            ArrangementMarker(name: "Verse", startSeconds: 0, sortOrder: 0),
        ]
        let slots = SongArrangementStore.defaultSlots(from: markers)
        let trackID = UUID()
        let slotID = slots[0].id

        let regions = SongArrangementStore.migrateClipGapsToRegions(
            slots: slots,
            clipTrims: [],
            clipGaps: [
                ArrangementClipGap(
                    slotID: slotID,
                    trackID: trackID,
                    sourceStartSeconds: 10,
                    sourceEndSeconds: 20
                ),
            ],
            removedClips: [],
            inputs: SongArrangementStore.makeLayoutInputs(
                markers: markers,
                trackIDs: [trackID],
                sourceDurationForTrack: { _ in 60 }
            ),
            sourceTracks: []
        )

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].sourceEndSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(regions[1].sourceStartSeconds, 20, accuracy: 0.001)
        XCTAssertGreaterThan(
            regions[1].timelineStartSeconds,
            regions[0].timelineEndSeconds + 0.001
        )
    }

    func testRegionTrimRespectsSplitNeighborBounds() {
        let trackID = UUID()
        let leftID = UUID()
        let rightID = UUID()
        let regions = [
            ClipRegion(
                id: leftID,
                slotID: trackID,
                trackID: trackID,
                markerID: trackID,
                sourceStartSeconds: 0,
                sourceEndSeconds: 10,
                timelineStartSeconds: 0,
                timelineEndSeconds: 10
            ),
            ClipRegion(
                id: rightID,
                slotID: trackID,
                trackID: trackID,
                markerID: trackID,
                sourceStartSeconds: 10,
                sourceEndSeconds: 20,
                timelineStartSeconds: 10,
                timelineEndSeconds: 20
            ),
        ]

        let trimmedRight = ClipRegionStore.regionByTrimmingEdge(
            regions[1],
            edge: .leading,
            timelineOffset: 2,
            in: regions,
            boundsStart: 0,
            boundsEnd: 30
        )
        XCTAssertEqual(trimmedRight.timelineStartSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(trimmedRight.sourceStartSeconds, 12, accuracy: 0.001)

        let extendedBack = ClipRegionStore.regionByTrimmingEdge(
            trimmedRight,
            edge: .leading,
            timelineOffset: -2,
            in: regions,
            boundsStart: 0,
            boundsEnd: 30
        )
        XCTAssertEqual(extendedBack.timelineStartSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(extendedBack.sourceStartSeconds, 10, accuracy: 0.001)

        let extendPastNeighbor = ClipRegionStore.regionByTrimmingEdge(
            trimmedRight,
            edge: .leading,
            timelineOffset: -3,
            in: regions,
            boundsStart: 0,
            boundsEnd: 30
        )
        XCTAssertEqual(extendPastNeighbor.timelineStartSeconds, 10, accuracy: 0.001)
    }
}
