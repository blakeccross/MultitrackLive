import Foundation
import SwiftData

@Model
final class TrackGroup {
    var id: UUID
    var name: String
    var sortOrder: Int

    init(name: String, sortOrder: Int) {
        id = UUID()
        self.name = name
        self.sortOrder = sortOrder
    }
}
