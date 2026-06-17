import Foundation
import SwiftData

enum PersistenceController {
    /// Bump when arrangement marker storage changes so stale rows are discarded.
    private static let storeVersion = 11
    private static let storeVersionKey = "SwiftDataStoreVersion"

    static let modelTypes: [any PersistentModel.Type] = [
        Song.self,
        AudioTrack.self,
        TrackGroup.self,
        OutputRoutingConfig.self,
        GroupOutputRoute.self,
        Setlist.self,
        SetlistEntry.self,
    ]

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(schema: schema)

        migrateStoreIfNeeded(at: configuration.url)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            resetStore(at: configuration.url)
            UserDefaults.standard.set(storeVersion, forKey: storeVersionKey)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    private static func migrateStoreIfNeeded(at url: URL) {
        let storedVersion = UserDefaults.standard.integer(forKey: storeVersionKey)
        guard storedVersion < storeVersion else { return }

        resetStore(at: url)
        UserDefaults.standard.set(storeVersion, forKey: storeVersionKey)
    }

    private static func resetStore(at url: URL) {
        let fileManager = FileManager.default
        let relatedURLs = [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal"),
        ]

        for storeURL in relatedURLs where fileManager.fileExists(atPath: storeURL.path) {
            try? fileManager.removeItem(at: storeURL)
        }
    }
}
