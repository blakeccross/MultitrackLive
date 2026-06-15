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
