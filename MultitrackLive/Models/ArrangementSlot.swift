import Foundation

struct ArrangementSlot: Codable, Identifiable, Hashable {
    let id: UUID
    let markerID: UUID

    init(id: UUID = UUID(), markerID: UUID) {
        self.id = id
        self.markerID = markerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        markerID = try container.decode(UUID.self, forKey: .markerID)
    }
}

struct ArrangementClipTrim: Codable, Hashable {
    let slotID: UUID
    let trackID: UUID
    var leadingTrim: TimeInterval
    var trailingTrim: TimeInterval

    init(
        slotID: UUID,
        trackID: UUID,
        leadingTrim: TimeInterval = 0,
        trailingTrim: TimeInterval = 0
    ) {
        self.slotID = slotID
        self.trackID = trackID
        self.leadingTrim = leadingTrim
        self.trailingTrim = trailingTrim
    }
}

struct ArrangementRemovedClip: Codable, Hashable {
    let slotID: UUID
    let trackID: UUID
}

struct ArrangementClipGap: Codable, Hashable {
    let slotID: UUID
    let trackID: UUID
    var sourceStartSeconds: TimeInterval
    var sourceEndSeconds: TimeInterval
}

/// First-class clip region with explicit source and timeline bounds.
struct ClipRegion: Codable, Hashable, Identifiable {
    let id: UUID
    let slotID: UUID
    let trackID: UUID
    let markerID: UUID
    var sourceStartSeconds: TimeInterval
    var sourceEndSeconds: TimeInterval
    var timelineStartSeconds: TimeInterval
    var timelineEndSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        slotID: UUID,
        trackID: UUID,
        markerID: UUID,
        sourceStartSeconds: TimeInterval,
        sourceEndSeconds: TimeInterval,
        timelineStartSeconds: TimeInterval,
        timelineEndSeconds: TimeInterval
    ) {
        self.id = id
        self.slotID = slotID
        self.trackID = trackID
        self.markerID = markerID
        self.sourceStartSeconds = sourceStartSeconds
        self.sourceEndSeconds = sourceEndSeconds
        self.timelineStartSeconds = timelineStartSeconds
        self.timelineEndSeconds = timelineEndSeconds
    }
}

struct SongArrangement: Codable {
    var slots: [ArrangementSlot]
    var clipTrims: [ArrangementClipTrim]
    var removedClips: [ArrangementRemovedClip]
    /// Legacy gap storage; migrated to `clipRegions` on load when possible.
    var clipGaps: [ArrangementClipGap]
    var clipRegions: [ClipRegion]
    var loopSlotIDs: Set<UUID>

    enum CodingKeys: String, CodingKey {
        case slots
        case clipTrims
        case removedClips
        case clipGaps
        case clipRegions
        case loopSlotIDs
    }

    init(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim] = [],
        removedClips: [ArrangementRemovedClip] = [],
        clipGaps: [ArrangementClipGap] = [],
        clipRegions: [ClipRegion] = [],
        loopSlotIDs: Set<UUID> = []
    ) {
        self.slots = slots
        self.clipTrims = clipTrims
        self.removedClips = removedClips
        self.clipGaps = clipGaps
        self.clipRegions = clipRegions
        self.loopSlotIDs = loopSlotIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode([ArrangementSlot].self, forKey: .slots)
        clipTrims = try container.decodeIfPresent([ArrangementClipTrim].self, forKey: .clipTrims) ?? []
        removedClips = try container.decodeIfPresent([ArrangementRemovedClip].self, forKey: .removedClips) ?? []
        clipGaps = try container.decodeIfPresent([ArrangementClipGap].self, forKey: .clipGaps) ?? []
        clipRegions = try container.decodeIfPresent([ClipRegion].self, forKey: .clipRegions) ?? []
        loopSlotIDs = Set(try container.decodeIfPresent([UUID].self, forKey: .loopSlotIDs) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        try container.encode(clipTrims, forKey: .clipTrims)
        try container.encode(removedClips, forKey: .removedClips)
        try container.encode(clipGaps, forKey: .clipGaps)
        try container.encode(clipRegions, forKey: .clipRegions)
        try container.encode(Array(loopSlotIDs), forKey: .loopSlotIDs)
    }
}

enum TimelineClipSelection: Equatable, Hashable {
    /// `clipID` identifies the visible clip segment; `slotID` is the parent arrangement slot.
    /// `editTime` is the grid-snapped split cursor when the user clicks inside the clip body.
    case whole(clipID: UUID, slotID: UUID, trackID: UUID, editTime: TimeInterval? = nil)
    case range(clipID: UUID, slotID: UUID, trackID: UUID, start: TimeInterval, end: TimeInterval)

    var clipID: UUID {
        switch self {
        case .whole(let clipID, _, _, _), .range(let clipID, _, _, _, _):
            clipID
        }
    }

    var slotID: UUID {
        switch self {
        case .whole(_, let slotID, _, _), .range(_, let slotID, _, _, _):
            slotID
        }
    }

    var trackID: UUID {
        switch self {
        case .whole(_, _, let trackID, _), .range(_, _, let trackID, _, _):
            trackID
        }
    }

    var editTime: TimeInterval? {
        if case .whole(_, _, _, let editTime) = self { return editTime }
        return nil
    }

    var isWholeClip: Bool {
        if case .whole = self { return true }
        return false
    }
}

struct ArrangementLayoutInputs {
    let sortedMarkers: [ArrangementMarker]
    let markersByID: [UUID: ArrangementMarker]
    let trackIDs: [UUID]
    let sourceDurationForTrack: (UUID) -> TimeInterval
}

struct ArrangementLayoutSnapshot {
    let rulerSections: [ArrangementDisplaySection]
    let trackSections: [UUID: [ArrangementDisplaySection]]
}

struct ArrangementDisplaySection: Identifiable, Hashable {
    let id: UUID
    /// Parent arrangement slot. Matches `id` for unsplit clips.
    let slotID: UUID
    let markerID: UUID
    let name: String
    let sourceStartSeconds: TimeInterval
    let sourceEndSeconds: TimeInterval
    /// Visible clip bounds after per-track trim.
    let timelineStartSeconds: TimeInterval
    let timelineEndSeconds: TimeInterval
    /// Fixed arrangement column bounds shared across all tracks in this slot.
    let columnStartSeconds: TimeInterval
    let columnEndSeconds: TimeInterval

    var duration: TimeInterval {
        timelineEndSeconds - timelineStartSeconds
    }

    var columnDuration: TimeInterval {
        columnEndSeconds - columnStartSeconds
    }

    func containsTimelineTime(_ time: TimeInterval) -> Bool {
        time >= timelineStartSeconds && time < timelineEndSeconds
    }
}

extension Array where Element == ArrangementDisplaySection {
    func section(atTimeline time: TimeInterval) -> ArrangementDisplaySection? {
        first { $0.containsTimelineTime(time) }
    }

    func loopSectionCandidate(
        at time: TimeInterval,
        loopSlotIDs: Set<UUID>,
        suppressedSectionIDs: Set<UUID>
    ) -> ArrangementDisplaySection? {
        first {
            loopSlotIDs.contains($0.id)
                && !suppressedSectionIDs.contains($0.id)
                && $0.containsTimelineTime(time)
        }
    }

    /// True when timeline positions match source positions with no gaps (e.g. fresh Ableton import).
    var usesSourceLinearTimeline: Bool {
        guard !isEmpty else { return false }

        let sorted = sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }
        guard sorted.allSatisfy({
            abs($0.columnStartSeconds - $0.sourceStartSeconds) < 0.001
        }) else {
            return false
        }

        for index in 0..<(sorted.count - 1) {
            if sorted[index + 1].timelineStartSeconds - sorted[index].timelineEndSeconds > 0.001 {
                return false
            }
        }
        return true
    }
}
