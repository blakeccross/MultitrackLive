import Foundation
import OSLog
import SwiftData

enum PersistenceController {
    /// Bump when arrangement marker storage changes so stale rows are discarded.
    private static let storeVersion = 19
    private static let storeVersionKey = "SwiftDataStoreVersion"
    private static let logger = Logger(subsystem: "com.blakecross.MultitrackLive", category: "Persistence")

    static let modelTypes: [any PersistentModel.Type] = [
        Song.self,
        AudioTrack.self,
        MIDITrack.self,
        MIDIDevice.self,
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
            logger.error("SwiftData store open failed; removing store and retrying: \(error.localizedDescription, privacy: .public)")
            resetStore(at: configuration.url, reason: "ModelContainer open failed")
            UserDefaults.standard.set(storeVersion, forKey: storeVersionKey)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    private static func migrateStoreIfNeeded(at url: URL) {
        let storedVersion = UserDefaults.standard.integer(forKey: storeVersionKey)
        guard storedVersion < storeVersion else { return }

        logger.notice("Resetting SwiftData store for schema migration \(storedVersion, privacy: .public) → \(self.storeVersion, privacy: .public)")
        resetStore(at: url, reason: "schema version migration")
        UserDefaults.standard.set(storeVersion, forKey: storeVersionKey)
    }

    private static func resetStore(at url: URL, reason: String) {
        let fileManager = FileManager.default
        let relatedURLs = [
            url,
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-wal"),
        ]

        for storeURL in relatedURLs where fileManager.fileExists(atPath: storeURL.path) {
            logger.error("Removing SwiftData file (\(reason, privacy: .public)): \(storeURL.path, privacy: .public)")
            try? fileManager.removeItem(at: storeURL)
        }
    }
}
