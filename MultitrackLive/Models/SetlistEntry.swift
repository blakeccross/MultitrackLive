import Foundation
import SwiftData

@Model
final class SetlistEntry {
    var sortOrder: Int
    var song: Song?
    var setlist: Setlist?

    init(sortOrder: Int, song: Song) {
        self.sortOrder = sortOrder
        self.song = song
    }
}
