import SwiftData
import SwiftUI

@main
struct MultitrackLiveApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try PersistenceController.makeContainer()
        } catch {
            fatalError("Could not initialize app storage: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
