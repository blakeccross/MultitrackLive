import Foundation

enum SongArrangementStore {
    private static let fileName = "arrangement-sequence.json"
    static let minimumClipDuration: TimeInterval = 0.1

    static func fileURL(for songID: UUID) -> URL {
        FileStore.songDirectory(for: songID).appendingPathComponent(fileName)
    }

    static func load(for songID: UUID, markers: [ArrangementMarker]) -> SongArrangement {
        let url = fileURL(for: songID)
        if let data = try? Data(contentsOf: url),
           let arrangement = try? JSONDecoder().decode(SongArrangement.self, from: data) {
            let hadMatchingSlots = !validatedSlots(arrangement.slots, markers: markers).isEmpty
            let result = validated(arrangement, markers: markers)
            if !hadMatchingSlots, !result.slots.isEmpty {
                try? save(result, for: songID)
            }
            return result
        }
        return SongArrangement(slots: defaultSlots(from: markers), clipTrims: [], removedClips: [])
    }

    static func save(_ arrangement: SongArrangement, for songID: UUID) throws {
        try FileStore.ensureSongDirectory(for: songID)
        let data = try JSONEncoder().encode(arrangement)
        try data.write(to: fileURL(for: songID), options: .atomic)
    }

    static func save(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        loopSlotIDs: Set<UUID> = [],
        for songID: UUID
    ) throws {
        try save(
            SongArrangement(
                slots: slots,
                clipTrims: clipTrims,
                removedClips: removedClips,
                loopSlotIDs: loopSlotIDs
            ),
            for: songID
        )
    }

    static func saveAsync(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        loopSlotIDs: Set<UUID> = [],
        for songID: UUID
    ) {
        let arrangement = SongArrangement(
            slots: slots,
            clipTrims: clipTrims,
            removedClips: removedClips,
            loopSlotIDs: loopSlotIDs
        )
        Task.detached(priority: .utility) {
            try? save(arrangement, for: songID)
        }
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
                        columns: columns,
                        inputs: inputs
                    )
                )
            }
        )
        return ArrangementLayoutSnapshot(rulerSections: rulerSections, trackSections: trackSections)
    }

    static func delete(for songID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: songID))
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
        removedClips: inout [ArrangementRemovedClip]
    ) {
        let removed = ArrangementRemovedClip(slotID: slotID, trackID: trackID)
        if !removedClips.contains(removed) {
            removedClips.append(removed)
        }
        clipTrims.removeAll { $0.slotID == slotID && $0.trackID == trackID }
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
            columns: columns,
            inputs: inputs
        )
    }

    static func trackDisplaySections(
        for trackID: UUID,
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
        inputs: ArrangementLayoutInputs
    ) -> [ArrangementDisplaySection] {
        let columns = arrangementColumns(slots: slots, inputs: inputs)
        return trackDisplaySections(
            for: trackID,
            clipTrims: clipTrims,
            removedClips: removedClips,
            columns: columns,
            inputs: inputs
        )
    }

    private static func trackDisplaySections(
        for trackID: UUID,
        clipTrims: [ArrangementClipTrim],
        removedClips: [ArrangementRemovedClip],
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
            let trims = clampedTrims(
                slotID: column.slot.id,
                trackID: trackID,
                marker: column.marker,
                sortedMarkers: inputs.sortedMarkers,
                clipTrims: clipTrims,
                sourceDuration: sourceDuration
            )
            let trackUntrimmedDuration = bounds.end - bounds.start

            sections.append(
                ArrangementDisplaySection(
                    id: column.slot.id,
                    markerID: column.marker.id,
                    name: column.marker.name,
                    sourceStartSeconds: sourceRange.start,
                    sourceEndSeconds: sourceRange.end,
                    timelineStartSeconds: column.columnStart + trims.leading,
                    timelineEndSeconds: column.columnStart + trackUntrimmedDuration - trims.trailing,
                    columnStartSeconds: column.columnStart,
                    columnEndSeconds: columnEnd
                )
            )
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
        var masterTimeline: TimeInterval = 0
        var columns: [ArrangementColumn] = []

        for slot in slots {
            guard let marker = inputs.markersByID[slot.markerID] else { continue }

            let columnStart = masterTimeline
            let columnWidth = slotColumnWidth(
                marker: marker,
                sortedMarkers: inputs.sortedMarkers,
                trackIDs: inputs.trackIDs,
                sourceDurationForTrack: inputs.sourceDurationForTrack
            )
            columns.append(
                ArrangementColumn(
                    slot: slot,
                    marker: marker,
                    columnStart: columnStart,
                    columnWidth: columnWidth
                )
            )
            masterTimeline += columnWidth
        }

        return columns
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
            loopSlotIDs = Set(arrangement.loopSlotIDs.compactMap { slotIDMap[$0] })
        }

        let validSlotIDs = Set(validSlots.map(\.id))
        let validTrims = clipTrims.filter { validSlotIDs.contains($0.slotID) }
        let validRemoved = removedClips.filter { validSlotIDs.contains($0.slotID) }
        loopSlotIDs = loopSlotIDs.intersection(validSlotIDs)
        return SongArrangement(
            slots: validSlots,
            clipTrims: validTrims,
            removedClips: validRemoved,
            loopSlotIDs: loopSlotIDs
        )
    }

    private static func validatedSlots(_ slots: [ArrangementSlot], markers: [ArrangementMarker]) -> [ArrangementSlot] {
        let validMarkerIDs = Set(markers.map(\.id))
        return slots.filter { validMarkerIDs.contains($0.markerID) }
    }
}
