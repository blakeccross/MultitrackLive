import Foundation
import SwiftData

@Model
final class GroupOutputRoute {
    var groupID: UUID
    var destinationKind: String
    var destinationChannel: Int

    init(groupID: UUID, destination: OutputDestination) {
        self.groupID = groupID
        switch destination {
        case .stereoPair(let startChannel):
            destinationKind = "stereo"
            destinationChannel = startChannel
        case .mono(let channel):
            destinationKind = "mono"
            destinationChannel = channel
        }
    }

    var destination: OutputDestination {
        get {
            if destinationKind == "mono" {
                return .mono(channel: destinationChannel)
            }
            return .stereoPair(startChannel: destinationChannel)
        }
        set {
            switch newValue {
            case .stereoPair(let startChannel):
                destinationKind = "stereo"
                destinationChannel = startChannel
            case .mono(let channel):
                destinationKind = "mono"
                destinationChannel = channel
            }
        }
    }
}
