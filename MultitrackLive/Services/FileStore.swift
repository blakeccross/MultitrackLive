import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum FileStore {
    static let supportedTypes: [UTType] = [.wav, .aiff, .audio, .mp3, .mpeg4Audio]

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func songDirectory(for songID: UUID) -> URL {
        documentsDirectory
            .appendingPathComponent("Songs", isDirectory: true)
            .appendingPathComponent(songID.uuidString, isDirectory: true)
    }

    static func trackURL(songID: UUID, relativePath: String) -> URL {
        songDirectory(for: songID).appendingPathComponent(relativePath)
    }

    static func ensureSongDirectory(for songID: UUID) throws {
        let directory = songDirectory(for: songID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    static func importTracks(
        from sourceURLs: [URL],
        into song: Song
    ) throws -> [AudioTrack] {
        try ensureSongDirectory(for: song.id)

        var importedTracks: [AudioTrack] = []
        let existingCount = song.tracks.count

        for (index, sourceURL) in sourceURLs.enumerated() {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fileName = sourceURL.lastPathComponent
            let trackID = UUID()
            let fileExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension
            let destinationName = "\(trackID.uuidString).\(fileExtension)"
            let destinationURL = songDirectory(for: song.id).appendingPathComponent(destinationName)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let displayName = fileName
                .replacingOccurrences(of: ".\(fileExtension)", with: "", options: .caseInsensitive)

            let track = AudioTrack(
                displayName: displayName,
                relativeFilePath: destinationName,
                sortOrder: existingCount + index
            )
            track.song = song
            importedTracks.append(track)
        }

        return importedTracks
    }

    static func deleteSongFiles(for songID: UUID) {
        ArrangementMarkerStore.delete(for: songID)
        TimeSignatureStore.delete(for: songID)
        SongArrangementStore.delete(for: songID)
        let directory = songDirectory(for: songID)
        try? FileManager.default.removeItem(at: directory)
    }

    static func copyTrackFile(
        from sourceSongID: UUID,
        to destinationSongID: UUID,
        relativePath: String,
        newTrackID: UUID
    ) throws -> String {
        try ensureSongDirectory(for: destinationSongID)

        let sourceURL = trackURL(songID: sourceSongID, relativePath: relativePath)
        let fileExtension = (relativePath as NSString).pathExtension
        let destinationName = "\(newTrackID.uuidString).\(fileExtension.isEmpty ? "audio" : fileExtension)"
        let destinationURL = trackURL(songID: destinationSongID, relativePath: destinationName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationName
    }

    static func copyArrangementData(
        from sourceSongID: UUID,
        to destinationSongID: UUID,
        trackIDMap: [UUID: UUID]
    ) throws {
        let markers = ArrangementMarkerStore.load(for: sourceSongID)
        try ArrangementMarkerStore.save(markers, for: destinationSongID)

        let timeSignatures = TimeSignatureStore.load(for: sourceSongID)
        try TimeSignatureStore.save(timeSignatures, for: destinationSongID)

        var arrangement = SongArrangementStore.load(for: sourceSongID, markers: markers)
        arrangement.clipTrims = arrangement.clipTrims.map { trim in
            ArrangementClipTrim(
                slotID: trim.slotID,
                trackID: trackIDMap[trim.trackID] ?? trim.trackID,
                leadingTrim: trim.leadingTrim,
                trailingTrim: trim.trailingTrim
            )
        }
        arrangement.removedClips = arrangement.removedClips.map { removed in
            ArrangementRemovedClip(
                slotID: removed.slotID,
                trackID: trackIDMap[removed.trackID] ?? removed.trackID
            )
        }
        try SongArrangementStore.save(arrangement, for: destinationSongID)
    }

    static func fileDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
