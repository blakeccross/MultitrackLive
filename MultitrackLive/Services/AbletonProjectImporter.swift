import Compression
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum AbletonProjectImporter {
    static let abletonLiveSetType = UTType(filenameExtension: "als") ?? .data

    struct ImportResult {
        let bpm: Double
        let sections: [(name: String, startSeconds: TimeInterval)]
    }

    enum ImportError: LocalizedError {
        case unreadableFile
        case invalidFormat
        case missingTempo
        case noLocators

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "Could not read the Ableton project file."
            case .invalidFormat:
                return "This file does not appear to be a valid Ableton Live Set."
            case .missingTempo:
                return "No tempo was found in the Ableton project."
            case .noLocators:
                return "No arrangement locators were found in the Ableton project."
            }
        }
    }

    static func importFrom(url: URL) throws -> ImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let xmlData = try gunzip(data)
        let parsed = try parseProject(xmlData)

        guard let bpm = parsed.bpm, bpm > 0 else {
            throw ImportError.missingTempo
        }

        guard !parsed.locators.isEmpty else {
            throw ImportError.noLocators
        }

        let sortedLocators = parsed.locators.sorted { $0.beats < $1.beats }
        let sections = sortedLocators.map { locator in
            (
                name: locator.name,
                startSeconds: locator.beats * 60.0 / bpm
            )
        }

        return ImportResult(bpm: bpm, sections: sections)
    }

    static func apply(
        _ result: ImportResult,
        markers: [ArrangementMarker],
        to song: Song,
        context: ModelContext
    ) throws {
        song.bpm = result.bpm
        try ArrangementMarkerStore.save(markers, for: song.id)
        try context.save()
    }

    static func makeMarkers(from result: ImportResult) -> [ArrangementMarker] {
        result.sections.enumerated().map { index, section in
            ArrangementMarker(
                name: section.name,
                startSeconds: section.startSeconds,
                sortOrder: index
            )
        }
    }

    private static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else {
            throw ImportError.invalidFormat
        }

        let headerSize = 10
        let trailerSize = 8
        let compressedSize = data.count - headerSize - trailerSize
        guard compressedSize > 0 else {
            throw ImportError.invalidFormat
        }

        let declaredSize = data.withUnsafeBytes { rawBuffer in
            Int(rawBuffer.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self))
        }
        var outputCapacity = max(declaredSize + 1_024, compressedSize * 4, 65_536)

        while outputCapacity <= 256 * 1024 * 1024 {
            var output = Data(count: outputCapacity)

            let decodedSize: Int = output.withUnsafeMutableBytes { outputBuffer in
                data.withUnsafeBytes { inputBuffer in
                    guard
                        let outputBase = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        let inputBase = inputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else {
                        return 0
                    }

                    return compression_decode_buffer(
                        outputBase,
                        outputCapacity,
                        inputBase.advanced(by: headerSize),
                        compressedSize,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if decodedSize > 0 {
                return output.prefix(decodedSize)
            }

            outputCapacity *= 2
        }

        throw ImportError.invalidFormat
    }

    private struct ParsedProject {
        var bpm: Double?
        var locators: [ParsedLocator]
    }

    private struct ParsedLocator {
        var name: String
        var beats: Double
    }

    private static func parseProject(_ data: Data) throws -> ParsedProject {
        let bpm = try parseMasterTempo(from: data)
        let locatorsXML = try extractArrangementLocatorsXML(from: data)
        let locators = try parseLocatorsXML(locatorsXML)
        return ParsedProject(bpm: bpm, locators: locators)
    }

    private static func parseMasterTempo(from data: Data) throws -> Double? {
        for trackTag in ["MasterTrack", "MainTrack"] {
            guard let trackData = findTag(trackTag, in: data) else { continue }
            guard let tempoData = findTag("Tempo", in: trackData) else { continue }
            guard let tempoXML = String(data: tempoData, encoding: .utf8) else { continue }

            let parser = TempoXMLParser()
            let xmlParser = XMLParser(data: Data(tempoXML.utf8))
            xmlParser.delegate = parser
            guard xmlParser.parse(), let bpm = parser.bpm else { continue }
            return bpm
        }

        return nil
    }

    private static func extractArrangementLocatorsXML(from data: Data) throws -> Data {
        guard let outerLocators = findTag("Locators", in: data) else {
            throw ImportError.noLocators
        }

        let searchStart = outerLocators.index(after: outerLocators.startIndex)
        guard searchStart < outerLocators.endIndex,
              let innerLocators = findTag("Locators", in: outerLocators, start: searchStart) else {
            throw ImportError.noLocators
        }

        let innerString = String(data: innerLocators, encoding: .utf8) ?? ""
        guard innerString.contains("<Locator") else {
            throw ImportError.noLocators
        }

        return innerLocators
    }

    private static func parseLocatorsXML(_ data: Data) throws -> [ParsedLocator] {
        let parser = LocatorsXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser

        guard xmlParser.parse() else {
            throw ImportError.invalidFormat
        }

        return parser.locators.map { ParsedLocator(name: $0.name, beats: $0.beats) }
    }

    private static func findTag(_ tag: String, in data: Data) -> Data? {
        findTag(tag, in: data, start: data.startIndex)
    }

    private static func findTag(_ tag: String, in data: Data, start: Data.Index) -> Data? {
        guard start < data.endIndex else { return nil }

        guard
            let startRange = data.range(of: Data("<\(tag)".utf8), in: start ..< data.endIndex),
            let endRange = data.range(of: Data("</\(tag)>".utf8), in: startRange.lowerBound ..< data.endIndex)
        else {
            return nil
        }

        return Data(data[startRange.lowerBound ..< endRange.upperBound])
    }
}

private final class TempoXMLParser: NSObject, XMLParserDelegate {
    private(set) var bpm: Double?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Manual", bpm == nil else { return }
        guard let value = attributeDict["Value"], let parsed = parseBPM(value) else { return }
        bpm = parsed
    }

    private func parseBPM(_ value: String) -> Double? {
        guard let bpm = Double(value.replacingOccurrences(of: ",", with: ".")), (20...999).contains(bpm) else {
            return nil
        }
        return bpm
    }
}

private final class LocatorsXMLParser: NSObject, XMLParserDelegate {
    private var currentLocatorName: String?
    private var currentLocatorBeats: Double?
    private var insideLocator = false

    private(set) var locators: [(name: String, beats: Double)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Locator":
            insideLocator = true
            currentLocatorName = nil
            currentLocatorBeats = nil
        case "Time" where insideLocator:
            if let value = attributeDict["Value"] {
                currentLocatorBeats = Double(value.replacingOccurrences(of: ",", with: "."))
            }
        case "Name" where insideLocator:
            if let value = attributeDict["Value"] {
                currentLocatorName = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Locator" else { return }

        if let beats = currentLocatorBeats {
            let name = currentLocatorName?.isEmpty == false ? currentLocatorName! : "Section \(locators.count + 1)"
            locators.append((name: name, beats: beats))
        }

        insideLocator = false
        currentLocatorName = nil
        currentLocatorBeats = nil
    }
}
