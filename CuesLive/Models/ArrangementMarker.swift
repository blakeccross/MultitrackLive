import Foundation

struct ArrangementMarker: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let startSeconds: Double
    let sortOrder: Int

    init(id: UUID = UUID(), name: String, startSeconds: Double, sortOrder: Int) {
        self.id = id
        self.name = name
        self.startSeconds = startSeconds
        self.sortOrder = sortOrder
    }
}

extension Array where Element == ArrangementMarker {
    var sortedByTime: [ArrangementMarker] {
        sorted {
            if $0.startSeconds != $1.startSeconds {
                return $0.startSeconds < $1.startSeconds
            }
            return $0.sortOrder < $1.sortOrder
        }
    }
}
