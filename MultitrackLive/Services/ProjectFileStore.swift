import Foundation

enum ProjectFileStore {
    enum StoreError: LocalizedError {
        case unsupportedFormat(Int)
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let version):
                return "Unsupported song project format version \(version)."
            case .unreadableFile:
                return "Could not read the song project file."
            }
        }
    }

    static var songsDirectory: URL {
        let directory = FileStore.documentsDirectory
            .appendingPathComponent("MultitrackLive", isDirectory: true)
            .appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func defaultProjectURL(for songName: String) -> URL {
        uniqueProjectURL(
            in: songsDirectory,
            baseName: sanitizedFileName(songName),
            extension: ProjectUTType.songProjectExtension
        )
    }

    static func projectURL(named fileName: String, adjacentTo folderURL: URL) -> URL {
        uniqueProjectURL(
            in: folderURL,
            baseName: sanitizedFileName(fileName),
            extension: ProjectUTType.songProjectExtension
        )
    }

    static func load(from url: URL) throws -> SongProjectDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(SongProjectDocument.self, from: data) else {
            throw StoreError.unreadableFile
        }
        guard document.formatVersion <= SongProjectDocument.currentFormatVersion else {
            throw StoreError.unsupportedFormat(document.formatVersion)
        }
        return document
    }

    static func save(_ document: SongProjectDocument, to url: URL) throws {
        var document = document
        document.modifiedAt = Date()
        document.formatVersion = SongProjectDocument.currentFormatVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    private static func uniqueProjectURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = trimmed.isEmpty ? "Untitled" : trimmed
        var candidate = directory.appendingPathComponent("\(safeBase).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeBase) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

enum ShowFileStore {
    enum StoreError: LocalizedError {
        case unsupportedFormat(Int)
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let version):
                return "Unsupported show file format version \(version)."
            case .unreadableFile:
                return "Could not read the show file."
            }
        }
    }

    static var showsDirectory: URL {
        let directory = FileStore.documentsDirectory
            .appendingPathComponent("MultitrackLive", isDirectory: true)
            .appendingPathComponent("Shows", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func defaultShowURL(for showName: String) -> URL {
        let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = trimmed.isEmpty ? "Untitled" : trimmed
        var candidate = showsDirectory.appendingPathComponent("\(safeBase).\(ProjectUTType.showProjectExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = showsDirectory.appendingPathComponent("\(safeBase) \(index).\(ProjectUTType.showProjectExtension)")
            index += 1
        }
        return candidate
    }

    static func load(from url: URL) throws -> ShowProjectDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ShowProjectDocument.self, from: data) else {
            throw StoreError.unreadableFile
        }
        guard document.formatVersion <= ShowProjectDocument.currentFormatVersion else {
            throw StoreError.unsupportedFormat(document.formatVersion)
        }
        return document
    }

    static func save(_ document: ShowProjectDocument, to url: URL) throws {
        var document = document
        document.modifiedAt = Date()
        document.formatVersion = ShowProjectDocument.currentFormatVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }
}
