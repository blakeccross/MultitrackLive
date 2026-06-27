import Foundation

enum SongArrangementStore {
    static let minimumClipDuration: TimeInterval = 0.1

    static func normalized(_ arrangement: SongArrangement, markers: [ArrangementMarker]) -> SongArrangement {
        validated(arrangement, markers: markers)
    }

    static func defaultArrangement(for markers: [ArrangementMarker]) -> SongArrangement {
        SongArrangement(
            slots: defaultSlots(from: markers),
            clipTrims: [],
            removedClips: [],
            clipGaps: [],
            clipRegions: []
        )
    }

    static func makeLayoutInputs(
        markers: [ArrangementMarker],
        trackIDs: [UUID],
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval
    ) -> ArrangementLayoutInputs {
        let sortedMarkers = markers.sortedByTime
        return ArrangementLayoutInputs(
            sortedMarkers: sortedMarkers,
            markersByID: Dictionary(uniqueKeysWithValues: sortedMarkers.map { ($0.id, $0) }),
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDurationForTrack
        )
    }

    static func buildLayoutSnapshot(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        inputs: ArrangementLayoutInputs
    ) -> ArrangementLayoutSnapshot {
        let columns = arrangementColumns(slots: slots, inputs: inputs)
        let rulerSections = rulerDisplaySections(columns: columns, inputs: inputs)
        let trackSections = Dictionary(
            uniqueKeysWithValues: inputs.trackIDs.map { trackID in
                (
                    trackID,
                    trackDisplaySections(
                        for: trackID,
                        clipTrims: clipTrims,
                        removedClips: removedClips,
                        clipGaps: clipGaps,
                        clipRegions: clipRegions,
                        columns: columns,
                        inputs: inputs
                    )
                )
            }
        )
        return ArrangementLayoutSnapshot(rulerSections: rulerSections, trackSections: trackSections)
    }

    /// Sections that drive audio playback, honoring source-track clip regions on source-linear layouts.
    static func playbackTrackSections(
        for trackID: UUID,
        trimStart: TimeInterval,
        trimEnd: TimeInterval,
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        inputs: ArrangementLayoutInputs,
        rulerSections: [ArrangementDisplaySection]
    ) -> [ArrangementDisplaySection] {
        if rulerSections.usesSourceLinearTimeline {
            return sourceTrackDisplaySections(
                trackID: trackID,
                trimStart: trimStart,
                trimEnd: trimEnd,
                clipGaps: clipGaps,
                clipRegions: clipRegions
            )
        }

        let sections = trackDisplaySections(
            for: trackID,
            slots: slots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            inputs: inputs
        )
        if !sections.isEmpty {
            return sections
        }

        return sourceTrackDisplaySections(
            trackID: trackID,
            trimStart: trimStart,
            trimEnd: trimEnd,
            clipGaps: clipGaps,
            clipRegions: clipRegions
        )
    }

    static func playbackLayoutSnapshot(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        tracks: [(id: UUID, trimStart: TimeInterval, trimEnd: TimeInterval)],
        inputs: ArrangementLayoutInputs
    ) -> ArrangementLayoutSnapshot {
        let layout = buildLayoutSnapshot(
            slots: slots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            inputs: inputs
        )
        let sectionsByTrack = Dictionary(
            uniqueKeysWithValues: tracks.map { track in
                (
                    track.id,
                    playbackTrackSections(
                        for: track.id,
                        trimStart: track.trimStart,
                        trimEnd: track.trimEnd,
                        slots: slots,
                        clipTrims: clipTrims,
                        removedClips: removedClips,
                        clipGaps: clipGaps,
                        clipRegions: clipRegions,
                        inputs: inputs,
                        rulerSections: layout.rulerSections
                    )
                )
            }
        )
        return ArrangementLayoutSnapshot(
            rulerSections: layout.rulerSections,
            trackSections: sectionsByTrack
        )
    }

    static func segmentID(slotID: UUID, index: Int) -> UUID {
        var bytes = slotID.uuid
        bytes.14 = UInt8((index >> 8) & 0xFF)
        bytes.15 = UInt8(index & 0xFF)
        return UUID(uuid: bytes)
    }

    static func gaps(
        slotID: UUID,
        trackID: UUID,
        in clipGaps: [ArrangementClipGap]
    ) -> [ArrangementClipGap] {
        clipGaps
            .filter { $0.slotID == slotID && $0.trackID == trackID }
            .sorted { $0.sourceStartSeconds < $1.sourceStartSeconds }
    }

    static func sourceSegments(
        from sourceStart: TimeInterval,
        to sourceEnd: TimeInterval,
        excluding gaps: [ArrangementClipGap]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var segments: [(start: TimeInterval, end: TimeInterval)] = [(sourceStart, sourceEnd)]

        for gap in gaps.sorted(by: { $0.sourceStartSeconds < $1.sourceStartSeconds }) {
            segments = segments.flatMap { segment -> [(TimeInterval, TimeInterval)] in
                if gap.sourceEndSeconds <= segment.start + 0.000_1
                    || gap.sourceStartSeconds >= segment.end - 0.000_1 {
                    return [segment]
                }

                var split: [(TimeInterval, TimeInterval)] = []
                if gap.sourceStartSeconds > segment.start + 0.000_1 {
                    split.append((segment.start, gap.sourceStartSeconds))
                }
                if gap.sourceEndSeconds < segment.end - 0.000_1 {
                    split.append((gap.sourceEndSeconds, segment.end))
                }
                return split
            }
        }

        return segments.filter { $0.end - $0.start >= minimumClipDuration }
    }

    static func addGap(
        slotID: UUID,
        trackID: UUID,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        in clipGaps: inout [ArrangementClipGap]
    ) {
        guard sourceEnd - sourceStart >= minimumClipDuration else { return }

        var merged = gaps(slotID: slotID, trackID: trackID, in: clipGaps)
        merged.append(
            ArrangementClipGap(
                slotID: slotID,
                trackID: trackID,
                sourceStartSeconds: sourceStart,
                sourceEndSeconds: sourceEnd
            )
        )
        merged.sort { $0.sourceStartSeconds < $1.sourceStartSeconds }

        var combined: [ArrangementClipGap] = []
        for gap in merged {
            guard let last = combined.last else {
                combined.append(gap)
                continue
            }
            if gap.sourceStartSeconds <= last.sourceEndSeconds + 0.000_1 {
                combined[combined.count - 1] = ArrangementClipGap(
                    slotID: slotID,
                    trackID: trackID,
                    sourceStartSeconds: last.sourceStartSeconds,
                    sourceEndSeconds: max(last.sourceEndSeconds, gap.sourceEndSeconds)
                )
            } else {
                combined.append(gap)
            }
        }

        clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }
        clipGaps.append(contentsOf: combined)
    }

    static func sourceRange(
        forTimelineRange range: ClosedRange<TimeInterval>,
        slotID: UUID,
        sections: [ArrangementDisplaySection]
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let slotSections = sections
            .filter { $0.slotID == slotID }
            .sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }

        var sourceStarts: [TimeInterval] = []
        var sourceEnds: [TimeInterval] = []

        for section in slotSections {
            let overlapStart = max(range.lowerBound, section.timelineStartSeconds)
            let overlapEnd = min(range.upperBound, section.timelineEndSeconds)
            guard overlapEnd - overlapStart >= minimumClipDuration else { continue }

            let offsetStart = overlapStart - section.timelineStartSeconds
            let offsetEnd = overlapEnd - section.timelineStartSeconds
            sourceStarts.append(section.sourceStartSeconds + offsetStart)
            sourceEnds.append(section.sourceStartSeconds + offsetEnd)
        }

        guard let start = sourceStarts.min(), let end = sourceEnds.max(), end - start >= minimumClipDuration else {
            return nil
        }
        return (start, end)
    }

    /// Builds timeline sections for a source-only track, preserving absolute timeline
    /// positions so deleted regions leave blank space instead of rippling later clips.
    static func sourceTrackDisplaySections(
        trackID: UUID,
        trimStart: TimeInterval,
        trimEnd: TimeInterval,
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = []
    ) -> [ArrangementDisplaySection] {
        let stored = ClipRegionStore.regions(slotID: trackID, trackID: trackID, in: clipRegions)
        if !stored.isEmpty {
            return stored.map {
                ClipRegionStore.displaySection(
                    from: $0,
                    name: "",
                    columnStart: trimStart,
                    columnEnd: trimEnd
                )
            }
        }

        let trackGaps = gaps(slotID: trackID, trackID: trackID, in: clipGaps)
        let segments = sourceSegments(from: trimStart, to: trimEnd, excluding: trackGaps)
        guard !segments.isEmpty else { return [] }

        return segments.enumerated().map { index, segment in
            let sectionID = segments.count == 1 ? trackID : segmentID(slotID: trackID, index: index)
            return ArrangementDisplaySection(
                id: sectionID,
                slotID: trackID,
                markerID: trackID,
                name: "",
                sourceStartSeconds: segment.start,
                sourceEndSeconds: segment.end,
                timelineStartSeconds: segment.start,
                timelineEndSeconds: segment.end,
                columnStartSeconds: trimStart,
                columnEndSeconds: trimEnd
            )
        }
    }

    static func defaultSlots(from markers: [ArrangementMarker]) -> [ArrangementSlot] {
        markers.sortedByTime.map { ArrangementSlot(markerID: $0.id) }
    }

    static func markerSourceRange(
        for marker: ArrangementMarker,
        markers: [ArrangementMarker],
        sourceDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        markerSourceRange(for: marker, sortedMarkers: markers.sortedByTime, sourceDuration: sourceDuration)
    }

    private static func markerSourceRange(
        for marker: ArrangementMarker,
        sortedMarkers: [ArrangementMarker],
        sourceDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let safeSourceDuration = max(sourceDuration, 0.001)
        guard let index = sortedMarkers.firstIndex(where: { $0.id == marker.id }) else {
            return (marker.startSeconds, safeSourceDuration)
        }
        let end: TimeInterval
        if index + 1 < sortedMarkers.count {
            end = sortedMarkers[index + 1].startSeconds
        } else {
            end = safeSourceDuration
        }
        return (marker.startSeconds, end)
    }

    static func trims(
        slotID: UUID,
        trackID: UUID,
        in clipTrims: [ArrangementClipTrim]
    ) -> (leading: TimeInterval, trailing: TimeInterval) {
        guard let match = clipTrims.first(where: { $0.slotID == slotID && $0.trackID == trackID }) else {
            return (0, 0)
        }
        return (match.leadingTrim, match.trailingTrim)
    }

    static func isClipRemoved(
        slotID: UUID,
        trackID: UUID,
        in removedClips: [ArrangementRemovedClip]
    ) -> Bool {
        removedClips.contains { $0.slotID == slotID && $0.trackID == trackID }
    }

    static func removeClip(
        slotID: UUID,
        trackID: UUID,
        clipTrims: inout [ArrangementClipTrim],
        removedClips: inout [ArrangementRemovedClip],
        clipGaps: inout [ArrangementClipGap],
        clipRegions: inout [ClipRegion]
    ) {
        let removed = ArrangementRemovedClip(slotID: slotID, trackID: trackID)
        if !removedClips.contains(removed) {
            removedClips.append(removed)
        }
        clipTrims.removeAll { $0.slotID == slotID && $0.trackID == trackID }
        clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }
        ClipRegionStore.removeAllRegions(slotID: slotID, trackID: trackID, in: &clipRegions)
    }

    static func ensureClipRegions(
        slotID: UUID,
        trackID: UUID,
        markerID: UUID,
        sourceRange: (start: TimeInterval, end: TimeInterval),
        boundsStart: TimeInterval,
        columnStart: TimeInterval,
        clipGaps: [ArrangementClipGap],
        clipRegions: inout [ClipRegion]
    ) {
        guard !ClipRegionStore.hasStoredRegions(slotID: slotID, trackID: trackID, in: clipRegions) else {
            return
        }
        clipRegions.append(
            contentsOf: ClipRegionStore.defaultRegions(
                slotID: slotID,
                trackID: trackID,
                markerID: markerID,
                sourceRange: sourceRange,
                boundsStart: boundsStart,
                columnStart: columnStart,
                gaps: clipGaps
            )
        )
    }

    static func ensureSourceTrackRegions(
        trackID: UUID,
        trimStart: TimeInterval,
        trimEnd: TimeInterval,
        clipGaps: [ArrangementClipGap],
        clipRegions: inout [ClipRegion]
    ) {
        guard !ClipRegionStore.hasStoredRegions(slotID: trackID, trackID: trackID, in: clipRegions) else {
            return
        }
        clipRegions.append(
            contentsOf: ClipRegionStore.defaultSourceTrackRegions(
                trackID: trackID,
                trimStart: trimStart,
                trimEnd: trimEnd,
                gaps: clipGaps
            )
        )
    }

    static func migrateClipGapsToRegions(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        clipGaps: [ArrangementClipGap],
        removedClips: [ArrangementRemovedClip],
        inputs: ArrangementLayoutInputs,
        sourceTracks: [(trackID: UUID, trimStart: TimeInterval, trimEnd: TimeInterval)]
    ) -> [ClipRegion] {
        var regions: [ClipRegion] = []
        let columns = arrangementColumns(slots: slots, inputs: inputs)

        for column in columns {
            for trackID in inputs.trackIDs {
                guard !isClipRemoved(slotID: column.slot.id, trackID: trackID, in: removedClips) else {
                    continue
                }
                let sourceDuration = inputs.sourceDurationForTrack(trackID)
                guard let sourceRange = trimmedSourceRange(
                    slot: column.slot,
                    trackID: trackID,
                    marker: column.marker,
                    sortedMarkers: inputs.sortedMarkers,
                    clipTrims: clipTrims,
                    sourceDuration: sourceDuration
                ) else { continue }

                let bounds = markerSourceRange(
                    for: column.marker,
                    sortedMarkers: inputs.sortedMarkers,
                    sourceDuration: sourceDuration
                )
                let slotGaps = gaps(slotID: column.slot.id, trackID: trackID, in: clipGaps)
                guard !slotGaps.isEmpty else { continue }

                regions.append(
                    contentsOf: ClipRegionStore.defaultRegions(
                        slotID: column.slot.id,
                        trackID: trackID,
                        markerID: column.marker.id,
                        sourceRange: sourceRange,
                        boundsStart: bounds.start,
                        columnStart: column.columnStart,
                        gaps: clipGaps
                    )
                )
            }
        }

        for track in sourceTracks {
            let trackGaps = gaps(slotID: track.trackID, trackID: track.trackID, in: clipGaps)
            guard !trackGaps.isEmpty else { continue }
            guard !regions.contains(where: { $0.slotID == track.trackID && $0.trackID == track.trackID }) else {
                continue
            }
            regions.append(
                contentsOf: ClipRegionStore.defaultSourceTrackRegions(
                    trackID: track.trackID,
                    trimStart: track.trimStart,
                    trimEnd: track.trimEnd,
                    gaps: clipGaps
                )
            )
        }

        return regions
    }

    /// Trims, splits, or removes an arrangement clip based on a timeline range selection.
    /// Returns `true` when the clip was removed entirely.
    @discardableResult
    static func deleteVisibleRange(
        slotID: UUID,
        trackID: UUID,
        rangeStart: TimeInterval,
        rangeEnd: TimeInterval,
        sections: [ArrangementDisplaySection],
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        sourceDuration: TimeInterval,
        clipTrims: inout [ArrangementClipTrim],
        removedClips: inout [ArrangementRemovedClip],
        clipGaps: inout [ArrangementClipGap],
        clipRegions: inout [ClipRegion],
        columnStart: TimeInterval
    ) -> Bool {
        let sortedMarkers = markers.sortedByTime
        let slotSections = sections
            .filter { $0.slotID == slotID }
            .sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        guard let visibleStart = slotSections.first?.timelineStartSeconds,
              let visibleEnd = slotSections.last?.timelineEndSeconds else {
            return false
        }

        let snapped = MeasureTiming.snapTimelineRangeToGrid(
            start: rangeStart,
            end: rangeEnd,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges
        )
        let selectionStart = max(snapped.start, visibleStart)
        let selectionEnd = min(snapped.end, visibleEnd)
        guard selectionEnd - selectionStart >= minimumClipDuration else { return false }

        guard let sourceRange = trimmedSourceRange(
            slot: ArrangementSlot(id: slotID, markerID: marker.id),
            trackID: trackID,
            marker: marker,
            sortedMarkers: sortedMarkers,
            clipTrims: clipTrims,
            sourceDuration: sourceDuration
        ) else { return false }

        let bounds = markerSourceRange(
            for: marker,
            sortedMarkers: sortedMarkers,
            sourceDuration: sourceDuration
        )

        ensureClipRegions(
            slotID: slotID,
            trackID: trackID,
            markerID: marker.id,
            sourceRange: sourceRange,
            boundsStart: bounds.start,
            columnStart: columnStart,
            clipGaps: clipGaps,
            clipRegions: &clipRegions
        )
        clipGaps.removeAll { $0.slotID == slotID && $0.trackID == trackID }

        let removedEntirely = ClipRegionStore.deleteTimelineRange(
            slotID: slotID,
            trackID: trackID,
            rangeStart: selectionStart,
            rangeEnd: selectionEnd,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            in: &clipRegions
        )

        if removedEntirely {
            removeClip(
                slotID: slotID,
                trackID: trackID,
                clipTrims: &clipTrims,
                removedClips: &removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions
            )
            return true
        }

        if ClipRegionStore.regions(slotID: slotID, trackID: trackID, in: clipRegions).isEmpty {
            removeClip(
                slotID: slotID,
                trackID: trackID,
                clipTrims: &clipTrims,
                removedClips: &removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions
            )
            return true
        }

        return false
    }

    @discardableResult
    static func splitRegion(
        regionID: UUID,
        at timelineTime: TimeInterval,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        clipRegions: inout [ClipRegion]
    ) -> UUID? {
        ClipRegionStore.splitRegion(
            regionID: regionID,
            at: timelineTime,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatureChanges,
            in: &clipRegions
        )
    }

    @discardableResult
    static func joinRegions(
        firstID: UUID,
        secondID: UUID,
        clipRegions: inout [ClipRegion]
    ) -> UUID? {
        ClipRegionStore.joinRegions(firstID: firstID, secondID: secondID, in: &clipRegions)
    }

    @discardableResult
    static func deleteRegion(
        regionID: UUID,
        slotID: UUID,
        trackID: UUID,
        clipTrims: inout [ArrangementClipTrim],
        removedClips: inout [ArrangementRemovedClip],
        clipGaps: inout [ArrangementClipGap],
        clipRegions: inout [ClipRegion]
    ) -> Bool {
        let deleted = ClipRegionStore.deleteRegion(regionID: regionID, in: &clipRegions)
        guard deleted else { return false }

        if ClipRegionStore.regions(slotID: slotID, trackID: trackID, in: clipRegions).isEmpty {
            removeClip(
                slotID: slotID,
                trackID: trackID,
                clipTrims: &clipTrims,
                removedClips: &removedClips,
                clipGaps: &clipGaps,
                clipRegions: &clipRegions
            )
            return true
        }
        return false
    }

    static func clampedTrims(
        slotID: UUID,
        trackID: UUID,
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        sourceDuration: TimeInterval
    ) -> (leading: TimeInterval, trailing: TimeInterval) {
        clampedTrims(
            slotID: slotID,
            trackID: trackID,
            marker: marker,
            sortedMarkers: markers.sortedByTime,
            clipTrims: clipTrims,
            sourceDuration: sourceDuration
        )
    }

    private static func clampedTrims(
        slotID: UUID,
        trackID: UUID,
        marker: ArrangementMarker,
        sortedMarkers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        sourceDuration: TimeInterval
    ) -> (leading: TimeInterval, trailing: TimeInterval) {
        let bounds = markerSourceRange(for: marker, sortedMarkers: sortedMarkers, sourceDuration: sourceDuration)
        let markerDuration = bounds.end - bounds.start
        let maxTrim = max(0, markerDuration - minimumClipDuration)

        let raw = trims(slotID: slotID, trackID: trackID, in: clipTrims)
        let leading = min(max(0, raw.leading), maxTrim)
        let trailing = min(max(0, raw.trailing), max(0, maxTrim - leading))
        return (leading, trailing)
    }

    static func trimmedSourceRange(
        slot: ArrangementSlot,
        trackID: UUID,
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        sourceDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        trimmedSourceRange(
            slot: slot,
            trackID: trackID,
            marker: marker,
            sortedMarkers: markers.sortedByTime,
            clipTrims: clipTrims,
            sourceDuration: sourceDuration
        )
    }

    private static func trimmedSourceRange(
        slot: ArrangementSlot,
        trackID: UUID,
        marker: ArrangementMarker,
        sortedMarkers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        sourceDuration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let bounds = markerSourceRange(for: marker, sortedMarkers: sortedMarkers, sourceDuration: sourceDuration)
        let trims = clampedTrims(
            slotID: slot.id,
            trackID: trackID,
            marker: marker,
            sortedMarkers: sortedMarkers,
            clipTrims: clipTrims,
            sourceDuration: sourceDuration
        )
        let effectiveStart = bounds.start + trims.leading
        let effectiveEnd = bounds.end - trims.trailing
        guard effectiveEnd - effectiveStart >= minimumClipDuration else { return nil }
        return (effectiveStart, effectiveEnd)
    }

    static func clipDuration(
        slot: ArrangementSlot,
        trackID: UUID,
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        sourceDuration: TimeInterval
    ) -> TimeInterval {
        guard let range = trimmedSourceRange(
            slot: slot,
            trackID: trackID,
            marker: marker,
            markers: markers,
            clipTrims: clipTrims,
            sourceDuration: sourceDuration
        ) else { return 0 }
        return range.end - range.start
    }

    static func trackDisplaySections(
        for trackID: UUID,
        slots: [ArrangementSlot],
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        trackIDs: [UUID],
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval
    ) -> [ArrangementDisplaySection] {
        let inputs = makeLayoutInputs(
            markers: markers,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDurationForTrack
        )
        let columns = arrangementColumns(slots: slots, inputs: inputs)
        return trackDisplaySections(
            for: trackID,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            columns: columns,
            inputs: inputs
        )
    }

    static func trackDisplaySections(
        for trackID: UUID,
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        inputs: ArrangementLayoutInputs
    ) -> [ArrangementDisplaySection] {
        let columns = arrangementColumns(slots: slots, inputs: inputs)
        return trackDisplaySections(
            for: trackID,
            clipTrims: clipTrims,
            removedClips: removedClips,
            clipGaps: clipGaps,
            clipRegions: clipRegions,
            columns: columns,
            inputs: inputs
        )
    }

    private static func trackDisplaySections(
        for trackID: UUID,
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        clipGaps: [ArrangementClipGap],
        clipRegions: [ClipRegion],
        columns: [ArrangementColumn],
        inputs: ArrangementLayoutInputs
    ) -> [ArrangementDisplaySection] {
        let sourceDuration = inputs.sourceDurationForTrack(trackID)
        var sections: [ArrangementDisplaySection] = []

        for column in columns {
            let columnEnd = column.columnStart + column.columnWidth

            if isClipRemoved(slotID: column.slot.id, trackID: trackID, in: removedClips) {
                continue
            }

            let storedRegions = ClipRegionStore.regions(
                slotID: column.slot.id,
                trackID: trackID,
                in: clipRegions
            )
            if !storedRegions.isEmpty {
                for region in storedRegions {
                    sections.append(
                        ClipRegionStore.displaySection(
                            from: region,
                            name: column.marker.name,
                            columnStart: column.columnStart,
                            columnEnd: columnEnd
                        )
                    )
                }
                continue
            }

            guard column.columnWidth >= minimumClipDuration,
                  let sourceRange = trimmedSourceRange(
                      slot: column.slot,
                      trackID: trackID,
                      marker: column.marker,
                      sortedMarkers: inputs.sortedMarkers,
                      clipTrims: clipTrims,
                      sourceDuration: sourceDuration
                  ) else {
                continue
            }

            let bounds = markerSourceRange(
                for: column.marker,
                sortedMarkers: inputs.sortedMarkers,
                sourceDuration: sourceDuration
            )
            let slotGaps = gaps(slotID: column.slot.id, trackID: trackID, in: clipGaps)
            let segments = sourceSegments(
                from: sourceRange.start,
                to: sourceRange.end,
                excluding: slotGaps
            )
            guard !segments.isEmpty else { continue }

            for (index, segment) in segments.enumerated() {
                let sectionID = segments.count == 1
                    ? column.slot.id
                    : segmentID(slotID: column.slot.id, index: index)
                let timelineStart = column.columnStart + (segment.start - bounds.start)
                let timelineEnd = column.columnStart + (segment.end - bounds.start)

                sections.append(
                    ArrangementDisplaySection(
                        id: sectionID,
                        slotID: column.slot.id,
                        markerID: column.marker.id,
                        name: column.marker.name,
                        sourceStartSeconds: segment.start,
                        sourceEndSeconds: segment.end,
                        timelineStartSeconds: timelineStart,
                        timelineEndSeconds: timelineEnd,
                        columnStartSeconds: column.columnStart,
                        columnEndSeconds: columnEnd
                    )
                )
            }
        }

        return sections
    }

    static func rulerDisplaySections(
        slots: [ArrangementSlot],
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        trackIDs: [UUID],
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval
    ) -> [ArrangementDisplaySection] {
        let inputs = makeLayoutInputs(
            markers: markers,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDurationForTrack
        )
        let columns = arrangementColumns(slots: slots, inputs: inputs)
        return rulerDisplaySections(columns: columns, inputs: inputs)
    }

    private static func rulerDisplaySections(
        columns: [ArrangementColumn],
        inputs: ArrangementLayoutInputs
    ) -> [ArrangementDisplaySection] {
        let maxSourceDuration = inputs.trackIDs.map(inputs.sourceDurationForTrack).max() ?? 1
        var sections: [ArrangementDisplaySection] = []

        for column in columns {
            guard column.columnWidth >= minimumClipDuration else { continue }

            let bounds = markerSourceRange(
                for: column.marker,
                sortedMarkers: inputs.sortedMarkers,
                sourceDuration: maxSourceDuration
            )
            let columnEnd = column.columnStart + column.columnWidth

            sections.append(
                ArrangementDisplaySection(
                    id: column.slot.id,
                    slotID: column.slot.id,
                    markerID: column.marker.id,
                    name: column.marker.name,
                    sourceStartSeconds: bounds.start,
                    sourceEndSeconds: bounds.end,
                    timelineStartSeconds: column.columnStart,
                    timelineEndSeconds: columnEnd,
                    columnStartSeconds: column.columnStart,
                    columnEndSeconds: columnEnd
                )
            )
        }

        return sections
    }

    static func masterTimelineDuration(
        slots: [ArrangementSlot],
        markers: [ArrangementMarker],
        clipTrims: [ArrangementClipTrim],
        trackIDs: [UUID],
        sourceDurationForTrack: @escaping (UUID) -> TimeInterval
    ) -> TimeInterval {
        rulerDisplaySections(
            slots: slots,
            markers: markers,
            clipTrims: clipTrims,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDurationForTrack
        ).last?.timelineEndSeconds ?? 0
    }

    static func setTrims(
        slotID: UUID,
        trackID: UUID,
        leading: TimeInterval,
        trailing: TimeInterval,
        in clipTrims: inout [ArrangementClipTrim]
    ) {
        if let index = clipTrims.firstIndex(where: { $0.slotID == slotID && $0.trackID == trackID }) {
            clipTrims[index].leadingTrim = leading
            clipTrims[index].trailingTrim = trailing
        } else {
            clipTrims.append(
                ArrangementClipTrim(
                    slotID: slotID,
                    trackID: trackID,
                    leadingTrim: leading,
                    trailingTrim: trailing
                )
            )
        }
    }

    private struct ArrangementColumn {
        let slot: ArrangementSlot
        let marker: ArrangementMarker
        let columnStart: TimeInterval
        let columnWidth: TimeInterval
    }

    private static func arrangementColumns(
        slots: [ArrangementSlot],
        inputs: ArrangementLayoutInputs
    ) -> [ArrangementColumn] {
        let usesSourceTimeline = usesSourceTimelineLayout(slots: slots, inputs: inputs)
        var masterTimeline: TimeInterval = 0
        var columns: [ArrangementColumn] = []

        for slot in slots {
            guard let marker = inputs.markersByID[slot.markerID] else { continue }

            let columnWidth = slotColumnWidth(
                marker: marker,
                sortedMarkers: inputs.sortedMarkers,
                trackIDs: inputs.trackIDs,
                sourceDurationForTrack: inputs.sourceDurationForTrack
            )
            let columnStart = usesSourceTimeline ? marker.startSeconds : masterTimeline
            columns.append(
                ArrangementColumn(
                    slot: slot,
                    marker: marker,
                    columnStart: columnStart,
                    columnWidth: columnWidth
                )
            )
            if !usesSourceTimeline {
                masterTimeline += columnWidth
            }
        }

        return columns
    }

    /// Fresh Ableton imports use one slot per marker in source-time order. Lay those out at
    /// absolute source positions. Reordered or duplicated slots use packed performance layout.
    private static func usesSourceTimelineLayout(
        slots: [ArrangementSlot],
        inputs: ArrangementLayoutInputs
    ) -> Bool {
        let sortedMarkers = inputs.sortedMarkers
        guard !slots.isEmpty, slots.count == sortedMarkers.count else { return false }

        var seenMarkerIDs = Set<UUID>()
        for (slot, marker) in zip(slots, sortedMarkers) {
            guard slot.markerID == marker.id, seenMarkerIDs.insert(slot.markerID).inserted else {
                return false
            }
        }
        return true
    }

    private static func slotColumnWidth(
        marker: ArrangementMarker,
        sortedMarkers: [ArrangementMarker],
        trackIDs: [UUID],
        sourceDurationForTrack: (UUID) -> TimeInterval
    ) -> TimeInterval {
        trackIDs
            .map { trackID in
                untrimmedClipDuration(
                    marker: marker,
                    sortedMarkers: sortedMarkers,
                    sourceDuration: sourceDurationForTrack(trackID)
                )
            }
            .max() ?? 0
    }

    private static func slotColumnWidth(
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        trackIDs: [UUID],
        sourceDurationForTrack: (UUID) -> TimeInterval
    ) -> TimeInterval {
        slotColumnWidth(
            marker: marker,
            sortedMarkers: markers.sortedByTime,
            trackIDs: trackIDs,
            sourceDurationForTrack: sourceDurationForTrack
        )
    }

    private static func untrimmedClipDuration(
        marker: ArrangementMarker,
        sortedMarkers: [ArrangementMarker],
        sourceDuration: TimeInterval
    ) -> TimeInterval {
        let bounds = markerSourceRange(for: marker, sortedMarkers: sortedMarkers, sourceDuration: sourceDuration)
        return max(0, bounds.end - bounds.start)
    }

    private static func untrimmedClipDuration(
        marker: ArrangementMarker,
        markers: [ArrangementMarker],
        sourceDuration: TimeInterval
    ) -> TimeInterval {
        untrimmedClipDuration(
            marker: marker,
            sortedMarkers: markers.sortedByTime,
            sourceDuration: sourceDuration
        )
    }

    private static func validated(_ arrangement: SongArrangement, markers: [ArrangementMarker]) -> SongArrangement {
        var validSlots = validatedSlots(arrangement.slots, markers: markers)
        var clipTrims = arrangement.clipTrims
        var removedClips = arrangement.removedClips
        var clipGaps = arrangement.clipGaps
        var clipRegions = arrangement.clipRegions
        var loopSlotIDs = arrangement.loopSlotIDs

        if validSlots.isEmpty,
           !markers.isEmpty,
           arrangement.slots.count == markers.sortedByTime.count {
            let recoveredSlots = defaultSlots(from: markers)
            let slotIDMap = Dictionary(
                uniqueKeysWithValues: zip(arrangement.slots.map(\.id), recoveredSlots.map(\.id))
            )
            validSlots = recoveredSlots
            clipTrims = arrangement.clipTrims.compactMap { trim in
                guard let newSlotID = slotIDMap[trim.slotID] else { return nil }
                return ArrangementClipTrim(
                    slotID: newSlotID,
                    trackID: trim.trackID,
                    leadingTrim: trim.leadingTrim,
                    trailingTrim: trim.trailingTrim
                )
            }
            removedClips = arrangement.removedClips.compactMap { removed in
                guard let newSlotID = slotIDMap[removed.slotID] else { return nil }
                return ArrangementRemovedClip(slotID: newSlotID, trackID: removed.trackID)
            }
            clipGaps = arrangement.clipGaps.compactMap { gap in
                guard let newSlotID = slotIDMap[gap.slotID] else { return nil }
                return ArrangementClipGap(
                    slotID: newSlotID,
                    trackID: gap.trackID,
                    sourceStartSeconds: gap.sourceStartSeconds,
                    sourceEndSeconds: gap.sourceEndSeconds
                )
            }
            clipRegions = arrangement.clipRegions.compactMap { region in
                guard let newSlotID = slotIDMap[region.slotID] else { return nil }
                return ClipRegion(
                    id: region.id,
                    slotID: newSlotID,
                    trackID: region.trackID,
                    markerID: region.markerID,
                    sourceStartSeconds: region.sourceStartSeconds,
                    sourceEndSeconds: region.sourceEndSeconds,
                    timelineStartSeconds: region.timelineStartSeconds,
                    timelineEndSeconds: region.timelineEndSeconds
                )
            }
            loopSlotIDs = Set(arrangement.loopSlotIDs.compactMap { slotIDMap[$0] })
        }

        let validSlotIDs = Set(validSlots.map(\.id))
        let validTrims = clipTrims.filter { validSlotIDs.contains($0.slotID) }
        let validRemoved = removedClips.filter { validSlotIDs.contains($0.slotID) }
        let validGaps = clipGaps.filter { validSlotIDs.contains($0.slotID) }
        let validRegions = clipRegions.filter { validSlotIDs.contains($0.slotID) }
        loopSlotIDs = loopSlotIDs.intersection(validSlotIDs)
        return SongArrangement(
            slots: validSlots,
            clipTrims: validTrims,
            removedClips: validRemoved,
            clipGaps: validGaps,
            clipRegions: validRegions,
            loopSlotIDs: loopSlotIDs
        )
    }

    private static func validatedSlots(_ slots: [ArrangementSlot], markers: [ArrangementMarker]) -> [ArrangementSlot] {
        let validMarkerIDs = Set(markers.map(\.id))
        return slots.filter { validMarkerIDs.contains($0.markerID) }
    }
}
