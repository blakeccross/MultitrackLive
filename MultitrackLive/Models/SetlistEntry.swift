import Foundation
import SwiftData

@Model
final class SetlistEntry {
    var sortOrder: Int
    var transitionRaw: String = SetlistTransition.continue.rawValue
    var song: Song?
    var setlist: Setlist?

    var transition: SetlistTransition {
        get { SetlistTransition(rawValue: transitionRaw) ?? .continue }
        set { transitionRaw = newValue.rawValue }
    }

    init(sortOrder: Int, song: Song, transition: SetlistTransition = .continue) {
        self.sortOrder = sortOrder
        self.transitionRaw = transition.rawValue
        self.song = song
    }
}
