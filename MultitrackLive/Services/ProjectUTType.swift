import Foundation
import UniformTypeIdentifiers

enum ProjectUTType {
    static let songProjectExtension = "mtlive"
    static let showProjectExtension = "mtliveshow"

    static var songProjectType: UTType {
        UTType(filenameExtension: songProjectExtension) ?? .json
    }

    static var showProjectType: UTType {
        UTType(filenameExtension: showProjectExtension) ?? .json
    }
}
