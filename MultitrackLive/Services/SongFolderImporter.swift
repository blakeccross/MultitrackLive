import Foundation
import SwiftData

enum SongFolderImporter {
    struct ScanResult {
        let suggestedName: String
        let abletonURL: URL?
        let trackURLs: [URL]
    }

    struct ImportResult {
        let song: Song
        let trackCount: Int
        let sectionCount: Int
        let bpm: Double?
    }

    enum ImportError: LocalizedError {
        case unreadableFolder
        case noImportableContent

        var errorDescription: String? {
            switch self {
            case .unreadableFolder:
                return "Could not read the selected folder."
            case .noImportableContent:
                return "No multitrack audio files were found in the folder. Add a Multitracks or Stems subfolder with audio files."
            }
        }
    }

    private static let preferredStemFolderNames = [
        "multitracks", "multitrack", "stems", "tracks", "audio"
    ]

    private static let supportedExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]

    static func scanFolder(at folderURL: URL) throws -> ScanResult {
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImportError.unreadableFolder
        }

        let suggestedName = folderURL.lastPathComponent
        let abletonURL = findAbletonFile(in: folderURL, folderName: suggestedName)
        let trackURLs = findTrackFiles(in: folderURL)

        guard abletonURL != nil || !trackURLs.isEmpty else {
            throw ImportError.noImportableContent
        }

        return ScanResult(
            suggestedName: suggestedName,
            abletonURL: abletonURL,
            trackURLs: trackURLs
        )
    }

    static func importFromFolder(
        at folderURL: URL,
        name: String? = nil,
        context: ModelContext
    ) throws -> ImportResult {
        let scan = try scanFolder(at: folderURL)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let songName = trimmedName.isEmpty ? scan.suggestedName : trimmedName

        let song = Song(name: songName)
        context.insert(song)

        do {
            let result = try applyScanResult(scan, to: song, context: context)
            try context.save()
            return ImportResult(
                song: song,
                trackCount: result.trackCount,
                sectionCount: result.sectionCount,
                bpm: result.bpm
            )
        } catch {
            context.delete(song)
            FileStore.deleteSongFiles(for: song.id)
            throw error
        }
    }

    static func importIntoExistingSong(
        at folderURL: URL,
        song: Song,
        context: ModelContext
    ) throws -> (trackCount: Int, sectionCount: Int, bpm: Double?) {
        let scan = try scanFolder(at: folderURL)
        let result = try applyScanResult(scan, to: song, context: context)
        try context.save()
        return (result.trackCount, result.sectionCount, result.bpm)
    }

    private struct AppliedScanResult {
        let trackCount: Int
        let sectionCount: Int
        let bpm: Double?
    }

    private static func applyScanResult(
        _ scan: ScanResult,
        to song: Song,
        context: ModelContext
    ) throws -> AppliedScanResult {
        var trackCount = 0
        var sectionCount = 0
        var bpm: Double?

        if !scan.trackURLs.isEmpty {
            let tracks = try FileStore.importTracks(from: scan.trackURLs, into: song)
            for track in tracks {
                context.insert(track)
                song.tracks.append(track)
            }
            trackCount = tracks.count
            TrackGroupStore.autoAssignGroups(for: song, in: context)
        }

        if let abletonURL = scan.abletonURL {
            let importResult = try AbletonProjectImporter.importFrom(url: abletonURL)
            let markers = AbletonProjectImporter.makeMarkers(from: importResult).sortedByTime
            try AbletonProjectImporter.apply(
                importResult,
                markers: markers,
                to: song,
                context: context
            )
            let slots = SongArrangementStore.defaultSlots(from: markers)
            try SongArrangementStore.save(
                slots: slots,
                clipTrims: [],
                removedClips: [],
                loopSlotIDs: [],
                for: song.id
            )
            sectionCount = importResult.sections.count
            bpm = importResult.bpm
        }

        guard trackCount > 0 else {
            throw ImportError.noImportableContent
        }

        return AppliedScanResult(trackCount: trackCount, sectionCount: sectionCount, bpm: bpm)
    }

    private static func findAbletonFile(in folderURL: URL, folderName: String) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let alsFiles = children.filter { $0.pathExtension.lowercased() == "als" }

        if alsFiles.count == 1 {
            return alsFiles[0]
        }

        if let matching = alsFiles.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == folderName.lowercased()
        }) {
            return matching
        }

        return alsFiles.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func findTrackFiles(in folderURL: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var directories: [(url: URL, name: String)] = []
        var rootAudio: [URL] = []

        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
            if values.isDirectory == true {
                directories.append((child, child.lastPathComponent.lowercased()))
            } else if isSupportedAudioFile(child) {
                rootAudio.append(child)
            }
        }

        for preferredName in preferredStemFolderNames {
            if let match = directories.first(where: { $0.name == preferredName }) {
                let tracks = audioFiles(in: match.url)
                if !tracks.isEmpty {
                    return tracks
                }
            }
        }

        let directoriesWithAudio = directories.compactMap { directory -> (URL, Int)? in
            let tracks = audioFiles(in: directory.url)
            return tracks.isEmpty ? nil : (directory.url, tracks.count)
        }

        if let best = directoriesWithAudio.max(by: { $0.1 < $1.1 }) {
            return audioFiles(in: best.0)
        }

        return rootAudio.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func audioFiles(in directory: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .filter(isSupportedAudioFile)
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
