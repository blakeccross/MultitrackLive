import Foundation
import SwiftData

@Model
final class OutputRoutingConfig {
    var id: UUID
    var selectedDeviceUID: String?

    init(selectedDeviceUID: String? = nil) {
        id = UUID()
        self.selectedDeviceUID = selectedDeviceUID
    }
}
