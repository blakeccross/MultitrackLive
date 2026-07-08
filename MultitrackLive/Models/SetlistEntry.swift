import Foundation
import SwiftData

@Model
final class SetlistEntry {
    var sortOrder: Int
    var transitionRaw: String = SetlistTransition.continue.rawValue
    var overlapStartOffsetSeconds: TimeInterval?
    var song: Song?
    var setlist: Setlist?
    var headerTitle: String?

    var isHeader: Bool {
        song == nil && headerTitle != nil
    }

    var transition: SetlistTransition {
        get { SetlistTransition(rawValue: transitionRaw) ?? .continue }
        set {
            transitionRaw = newValue.rawValue
            if !newValue.requiresOverlapConfig {
                overlapStartOffsetSeconds = nil
            }
        }
    }

    var overlapConfig: OverlapTransitionConfig? {
        get {
            guard let overlapStartOffsetSeconds else { return nil }
            return OverlapTransitionConfig(startOffsetSeconds: overlapStartOffsetSeconds)
        }
        set {
            overlapStartOffsetSeconds = newValue?.startOffsetSeconds
        }
    }

    init(sortOrder: Int, song: Song, transition: SetlistTransition = .continue) {
        self.sortOrder = sortOrder
        self.transitionRaw = transition.rawValue
        self.song = song
    }

    init(sortOrder: Int, headerTitle: String) {
        self.sortOrder = sortOrder
        self.headerTitle = headerTitle
    }
}
