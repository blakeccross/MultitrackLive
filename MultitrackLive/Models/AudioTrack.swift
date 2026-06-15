import Foundation
import SwiftData

@Model
final class AudioTrack {
    var id: UUID
    var displayName: String
    var relativeFilePath: String
    var sortOrder: Int
    var volume: Double
    var pan: Double
    var isMuted: Bool
    var isSolo: Bool
    var trimStartSeconds: Double
    var trimEndSeconds: Double?

    var song: Song?
    var group: TrackGroup?

    init(displayName: String, relativeFilePath: String, sortOrder: Int) {
        id = UUID()
        self.displayName = displayName
        self.relativeFilePath = relativeFilePath
        self.sortOrder = sortOrder
        volume = 1.0
        pan = 0.0
        isMuted = false
        isSolo = false
        trimStartSeconds = 0.0
        trimEndSeconds = nil
    }
}
