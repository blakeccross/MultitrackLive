import Foundation
import UniformTypeIdentifiers

enum ProjectUTType {
    static let songProjectExtension = "mtlive"
    static let showProjectExtension = "mtliveshow"
    /// Legacy opaque package extension; new exports are plain folders.
    static let setlistPackageExtension = "mtliveset"

    static var songProjectType: UTType {
        UTType(filenameExtension: songProjectExtension) ?? .json
    }

    static var showProjectType: UTType {
        UTType(filenameExtension: showProjectExtension) ?? .json
    }
}
