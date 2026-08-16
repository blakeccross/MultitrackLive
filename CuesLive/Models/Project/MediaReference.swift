import Foundation

enum MediaPathStyle: String, Codable, Hashable {
    case relativeToProject
    case absolute
}

/// External file reference stored in project documents (no embedded media).
struct MediaReference: Codable, Hashable {
    var path: String
    var pathStyle: MediaPathStyle
    var bookmark: Data?

    init(path: String, pathStyle: MediaPathStyle, bookmark: Data? = nil) {
        self.path = path
        self.pathStyle = pathStyle
        self.bookmark = bookmark
    }

    static func from(url: URL, relativeTo projectFileURL: URL?) -> MediaReference {
        let bookmark = MediaReferenceResolver.makeBookmark(for: url)
        if let projectFileURL,
           let relative = MediaReferenceResolver.relativePath(from: url, to: projectFileURL) {
            return MediaReference(path: relative, pathStyle: .relativeToProject, bookmark: bookmark)
        }
        return MediaReference(path: url.path, pathStyle: .absolute, bookmark: bookmark)
    }
}

/// Reference to another project document (e.g. a song in a show file).
struct ProjectDocumentReference: Codable, Hashable {
    var path: String
    var pathStyle: MediaPathStyle
    var bookmark: Data?

    init(path: String, pathStyle: MediaPathStyle, bookmark: Data? = nil) {
        self.path = path
        self.pathStyle = pathStyle
        self.bookmark = bookmark
    }

    static func from(projectURL: URL, relativeTo showFileURL: URL?) -> ProjectDocumentReference {
        let bookmark = MediaReferenceResolver.makeBookmark(for: projectURL)
        if let showFileURL,
           let relative = MediaReferenceResolver.relativePath(from: projectURL, to: showFileURL) {
            return ProjectDocumentReference(path: relative, pathStyle: .relativeToProject, bookmark: bookmark)
        }
        return ProjectDocumentReference(path: projectURL.path, pathStyle: .absolute, bookmark: bookmark)
    }
}
