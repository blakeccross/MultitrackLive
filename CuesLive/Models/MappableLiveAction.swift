import Foundation

/// Live-performance actions that can be bound to a key or MIDI note.
enum MappableLiveAction: Codable, Hashable, Identifiable, Sendable {
    case stop
    case playPause
    case fade
    case loop
    case goToSong(Int)

    static let transportActions: [MappableLiveAction] = [
        .stop,
        .playPause,
        .fade,
        .loop,
    ]

    var id: String {
        switch self {
        case .stop: "stop"
        case .playPause: "playPause"
        case .fade: "fade"
        case .loop: "loop"
        case .goToSong(let index): "goToSong.\(index)"
        }
    }

    var title: String {
        switch self {
        case .stop: "Stop"
        case .playPause: "Play"
        case .fade: "Fade"
        case .loop: "Loop"
        case .goToSong(let index): "Song \(index + 1)"
        }
    }

    var systemImage: String {
        switch self {
        case .stop: "stop.fill"
        case .playPause: "play.fill"
        case .fade: "righttriangle.fill"
        case .loop: "repeat"
        case .goToSong: "music.note"
        }
    }

    var sortOrder: Int {
        switch self {
        case .stop: 0
        case .playPause: 1
        case .fade: 2
        case .loop: 3
        case .goToSong(let index): 100 + index
        }
    }

    var songIndex: Int? {
        if case .goToSong(let index) = self {
            return index
        }
        return nil
    }
}
