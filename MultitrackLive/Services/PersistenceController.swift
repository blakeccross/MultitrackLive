import Foundation
import OSLog
import SwiftData

enum PersistenceController {
    /// Bump when arrangement marker storage changes so stale rows are discarded.
    private static let storeVersion = 21
    private static let storeVersionKey = "SwiftDataStoreVersion"
    private static let logger = Logger(subsystem: "com.blakecross.MultitrackLive", category: "Persistence")
    private static let storeDirectoryName = "com.blakecross.MultitrackLive"
    private static let storeFileName = "MultitrackLive.store"

    static let modelTypes: [any PersistentModel.Type] = [
        Song.self,
        AudioTrack.self,
        MIDITrack.self,
        MIDIDevice.self,
        TrackGroup.self,
        OutputRoutingConfig.self,
        GroupOutputRoute.self,
        TimecodeSettings.self,
        Setlist.self,
        SetlistEntry.self,
    ]

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let storeURL = try resolvedStoreURL()
        let configuration = ModelConfiguration(schema: schema, url: storeURL)

        migrateStoreIfNeeded(at: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            logger.error("SwiftData store open failed; removing store and retrying: \(error.localizedDescription, privacy: .public)")
            resetStore(at: storeURL, reason: "ModelContainer open failed")
            UserDefaults.standard.set(storeVersion, forKey: storeVersionKey)
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// App-specific store under Application Support. Never use the unnamed
    /// SwiftData default (`…/Application Support/default.store`), which collides
    /// with other unsandboxed apps on the same machine.
    private static func resolvedStoreURL() throws -> URL {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = applicationSupport.appendingPathComponent(storeDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeURL = directory.appendingPathComponent(storeFileName, isDirectory: false)
        migrateLegacyDefaultStoreIfNeeded(to: storeURL)
        return storeURL
    }

    /// If an older MultitrackLive build left data in the shared `default.store`,
    /// and that file actually contains our schema, move it into the app folder once.
    /// Foreign databases (e.g. Mail/API caches) at that path are left untouched.
    private static func migrateLegacyDefaultStoreIfNeeded(to destinationURL: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else { return }

        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let legacyURL = applicationSupport.appendingPathComponent("default.store", isDirectory: false)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        guard legacyStoreLooksLikeMultitrackLive(at: legacyURL) else {
            logger.notice("Ignoring foreign Application Support/default.store; starting a dedicated MultitrackLive store")
            return
        }

        logger.notice("Migrating legacy MultitrackLive SwiftData store to \(destinationURL.path, privacy: .public)")
        let relatedPairs: [(URL, URL)] = [
            (legacyURL, destinationURL),
            (
                URL(fileURLWithPath: legacyURL.path + "-shm"),
                URL(fileURLWithPath: destinationURL.path + "-shm")
            ),
            (
                URL(fileURLWithPath: legacyURL.path + "-wal"),
                URL(fileURLWithPath: destinationURL.path + "-wal")
            ),
        ]

        for (source, destination) in relatedPairs where fileManager.fileExists(atPath: source.path) {
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                logger.error("Failed to migrate \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func legacyStoreLooksLikeMultitrackLive(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        // Lightweight marker check: Multitrack entities use ZSONG / ZSETLIST table names.
        // Avoid opening a foreign SQLite DB with Core Data just to inspect it.
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let ascii = String(data: data, encoding: .ascii) else {
            return false
        }
        return ascii.contains("ZSONG") || ascii.contains("ZSETLIST")
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
