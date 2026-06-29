import Foundation
import SwiftData

@Model
final class TrackGroup {
    var id: UUID
    var name: String
    var sortOrder: Int
    var volume: Double = 1.0
    var isMuted: Bool = false

    init(name: String, sortOrder: Int, volume: Double = 1.0, isMuted: Bool = false) {
        id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.volume = volume
        self.isMuted = isMuted
    }
}
