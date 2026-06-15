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

    init(
        slots: [ArrangementSlot],
        clipTrims: [ArrangementClipTrim] = [],
        removedClips: [ArrangementRemovedClip] = []
    ) {
        self.slots = slots
        self.clipTrims = clipTrims
        self.removedClips = removedClips
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
