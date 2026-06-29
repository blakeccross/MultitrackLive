import Foundation
import SwiftData

struct GroupMixSnapshot: Sendable {
    let volumeByGroupID: [UUID: Float]
    let mutedGroupIDs: Set<UUID>
    let ungroupedVolume: Float
    let ungroupedIsMuted: Bool

    static let `default` = GroupMixSnapshot(
        volumeByGroupID: [:],
        mutedGroupIDs: [],
        ungroupedVolume: 1,
        ungroupedIsMuted: false
    )
}

enum GroupMixStore {
    static func snapshot(in context: ModelContext) -> GroupMixSnapshot {
        let groups = TrackGroupStore.sortedGroups(from: context)
        var volumeByGroupID: [UUID: Float] = [:]
        var mutedGroupIDs = Set<UUID>()

        for group in groups {
            volumeByGroupID[group.id] = Float(group.volume)
            if group.isMuted {
                mutedGroupIDs.insert(group.id)
            }
        }

        let config = OutputRoutingStore.config(in: context)
        return GroupMixSnapshot(
            volumeByGroupID: volumeByGroupID,
            mutedGroupIDs: mutedGroupIDs,
            ungroupedVolume: Float(config.ungroupedVolume),
            ungroupedIsMuted: config.ungroupedIsMuted
        )
    }
}
