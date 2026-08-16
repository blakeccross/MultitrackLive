import Foundation
import UniformTypeIdentifiers

enum ProjectUTType {
    static let songProjectExtension = "cueslive"
    static let showProjectExtension = "cueshow"
    /// Opaque package extension; new exports are plain folders.
    static let setlistPackageExtension = "cueset"

    static var songProjectType: UTType {
        UTType(filenameExtension: songProjectExtension) ?? .json
    }

    static var showProjectType: UTType {
        UTType(filenameExtension: showProjectExtension) ?? .json
    }
}
