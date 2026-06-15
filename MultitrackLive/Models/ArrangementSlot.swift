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

struct SongArrangement: Codable {
    var slots: [ArrangementSlot]
    var clipTrims: [ArrangementClipTrim]
    var removedClips: [ArrangementRemovedClip]
    var loopSlotIDs: Set<UUID>

    enum CodingKeys: String, CodingKey {
        case slots
        case clipTrims
        case removedClips
        case loopSlotIDs
    }

    init(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim] = [],
        removedClips: [ArrangementRemovedClip] = [],
        loopSlotIDs: Set<UUID> = []
    ) {
        self.slots = slots
        self.clipTrims = clipTrims
        self.removedClips = removedClips
        self.loopSlotIDs = loopSlotIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode([ArrangementSlot].self, forKey: .slots)
        clipTrims = try container.decodeIfPresent([ArrangementClipTrim].self, forKey: .clipTrims) ?? []
        removedClips = try container.decodeIfPresent([ArrangementRemovedClip].self, forKey: .removedClips) ?? []
        loopSlotIDs = Set(try container.decodeIfPresent([UUID].self, forKey: .loopSlotIDs) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        try container.encode(clipTrims, forKey: .clipTrims)
        try container.encode(removedClips, forKey: .removedClips)
        try container.encode(Array(loopSlotIDs), forKey: .loopSlotIDs)
    }
}

struct SelectedArrangementClip: Equatable, Hashable {
    let slotID: UUID
    let trackID: UUID
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
}
