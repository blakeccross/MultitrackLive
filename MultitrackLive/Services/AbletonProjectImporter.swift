import Compression
import Foundation
import SwiftData
import UniformTypeIdentifiers

enum AbletonProjectImporter {
    static let abletonLiveSetType = UTType(filenameExtension: "als") ?? .data

    /// Ableton's sentinel beat time for initial automation values.
    private static let initialAutomationBeatThreshold = -63_071_999.0

    struct ImportResult {
        let bpm: Double
        let sections: [(name: String, startSeconds: TimeInterval)]
        let timeSignatures: [TimeSignatureChange]
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

        let tempoChanges = [TempoChange(startMeasure: 1, bpm: bpm, sortOrder: 0)]
        let timeSignatures = buildImportedTimeSignatures(
            from: parsed.timeSignatures,
            tempoChanges: tempoChanges
        )

        return ImportResult(bpm: bpm, sections: sections, timeSignatures: timeSignatures)
    }

    private static func buildImportedTimeSignatures(
        from parsedSignatures: [ParsedTimeSignature],
        tempoChanges: [TempoChange]
    ) -> [TimeSignatureChange] {
        let sortedSignatures = parsedSignatures.sorted { $0.beats < $1.beats }
        var builtTimeSignatures: [TimeSignatureChange] = []

        for signature in sortedSignatures {
            let contextSignatures: [TimeSignatureChange]
            if builtTimeSignatures.isEmpty {
                contextSignatures = [
                    TimeSignatureChange(
                        numerator: signature.numerator,
                        denominator: signature.denominator,
                        startMeasure: 1,
                        sortOrder: 0
                    )
                ]
            } else {
                contextSignatures = builtTimeSignatures
            }

            if signature.beats > 0,
               let active = contextSignatures.sortedByMeasure.active(
                atMeasure: MeasureTiming.measureIndex(
                    atBeat: max(0, signature.beats - 0.001),
                    tempoChanges: tempoChanges,
                    timeSignatureChanges: contextSignatures
                )
               ),
               active.numerator == signature.numerator,
               active.denominator == signature.denominator {
                continue
            }

            let startMeasure: Int
            if signature.beats <= 0 {
                startMeasure = 1
            } else if let snapped = MeasureTiming.snappedMeasure(
                forBeat: signature.beats,
                timeSignatureChanges: contextSignatures
            ) {
                startMeasure = snapped
            } else {
                continue
            }

            if builtTimeSignatures.contains(where: { $0.startMeasure == startMeasure }) {
                continue
            }

            builtTimeSignatures.append(
                TimeSignatureChange(
                    numerator: signature.numerator,
                    denominator: signature.denominator,
                    startMeasure: startMeasure,
                    sortOrder: builtTimeSignatures.count
                )
            )
        }

        let defaultNumerator = sortedSignatures.first?.numerator ?? MeasureTiming.defaultNumerator
        let defaultDenominator = sortedSignatures.first?.denominator ?? MeasureTiming.defaultDenominator

        if builtTimeSignatures.isEmpty {
            return [
                TimeSignatureChange(
                    numerator: defaultNumerator,
                    denominator: defaultDenominator,
                    startMeasure: 1,
                    sortOrder: 0
                )
            ]
        }

        return builtTimeSignatures.normalizedEnsuringInitialMarker(
            defaultNumerator: defaultNumerator,
            defaultDenominator: defaultDenominator
        )
    }

    static func apply(
        _ result: ImportResult,
        markers: [ArrangementMarker],
        to song: Song,
        context: ModelContext
    ) throws {
        song.bpm = result.bpm
        if let initial = result.timeSignatures.sortedByMeasure.first {
            song.timeSignatureNumerator = initial.numerator
            song.timeSignatureDenominator = initial.denominator
        }
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
        var timeSignatures: [ParsedTimeSignature]
    }

    private struct ParsedLocator {
        var name: String
        var beats: Double
    }

    private struct ParsedTimeSignature {
        var numerator: Int
        var denominator: Int
        var beats: Double
    }

    private static func parseProject(_ data: Data) throws -> ParsedProject {
        let bpm = try parseMasterTempo(from: data)
        let locatorsXML = try extractArrangementLocatorsXML(from: data)
        let locators = try parseLocatorsXML(locatorsXML)
        let timeSignatures = parseArrangementTimeSignatures(from: data)
        return ParsedProject(bpm: bpm, locators: locators, timeSignatures: timeSignatures)
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

    private static func parseArrangementTimeSignatures(from data: Data) -> [ParsedTimeSignature] {
        guard let trackData = findTag("MasterTrack", in: data) ?? findTag("MainTrack", in: data),
              let xml = String(data: trackData, encoding: .utf8) else {
            return []
        }

        var events: [(beats: Double, enumValue: Int)] = []

        if let manualValue = firstMatch(
            in: xml,
            pattern: #"<TimeSignature>[\s\S]*?<Manual Value="(\d+)""#
        ), let value = Int(manualValue), value > 0 {
            events.append((beats: 0, enumValue: value))
        }

        if let automationEvents = firstMatch(
            in: xml,
            pattern: #"<TimeSignature>[\s\S]*?<ArrangerAutomation>[\s\S]*?<Events>([\s\S]*?)</Events>"#
        ) {
            events.append(contentsOf: parseEnumEvents(from: automationEvents))
        }

        if let automationTargetId = firstMatch(
            in: xml,
            pattern: #"<TimeSignature>[\s\S]*?<AutomationTarget Id="(\d+)""#
        ), let envelopeEvents = firstMatch(
            in: xml,
            pattern: #"<AutomationEnvelope[^>]*>[\s\S]*?<PointeeId Value="\#(automationTargetId)" />[\s\S]*?<Events>([\s\S]*?)</Events>"#
        ) {
            events.append(contentsOf: parseEnumEvents(from: envelopeEvents))
        } else if let envelopeEvents = firstMatch(
            in: xml,
            pattern: #"<AutomationEnvelope[^>]*>[\s\S]*?<PointeeId Value="10" />[\s\S]*?<Events>([\s\S]*?)</Events>"#
        ) {
            events.append(contentsOf: parseEnumEvents(from: envelopeEvents))
        } else {
            events.append(contentsOf: parseTimeSignatureEnumEventsFromEnvelopes(in: xml))
        }

        var signatures: [ParsedTimeSignature] = []
        var seenBeatKeys: Set<String> = []

        for event in events.sorted(by: { $0.beats < $1.beats }) {
            guard let decoded = AbletonTimeSignatureEncoding.decode(event.enumValue) else { continue }
            let beatKey = String(format: "%.6f|%d|%d", event.beats, decoded.numerator, decoded.denominator)
            guard seenBeatKeys.insert(beatKey).inserted else { continue }
            signatures.append(
                ParsedTimeSignature(
                    numerator: decoded.numerator,
                    denominator: decoded.denominator,
                    beats: event.beats
                )
            )
        }

        return signatures.sorted { $0.beats < $1.beats }
    }

    private static func parseTimeSignatureEnumEventsFromEnvelopes(in xml: String) -> [(beats: Double, enumValue: Int)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<AutomationEnvelope[^>]*>[\s\S]*?<Events>([\s\S]*?)</Events>"#
        ) else {
            return []
        }

        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        var events: [(beats: Double, enumValue: Int)] = []

        for match in regex.matches(in: xml, range: range) {
            guard match.numberOfRanges > 1,
                  let eventsRange = Range(match.range(at: 1), in: xml) else {
                continue
            }

            let eventsXML = String(xml[eventsRange])
            let parsed = parseEnumEvents(from: eventsXML).filter { event in
                (200...450).contains(event.enumValue)
            }
            guard parsed.contains(where: { $0.beats <= initialAutomationBeatThreshold || $0.beats == 0 }) else {
                continue
            }
            events.append(contentsOf: parsed)
        }

        return events
    }

    private static func parseEnumEvents(from eventsXML: String) -> [(beats: Double, enumValue: Int)] {
        let patterns = [
            (#"<EnumEvent[^>]*Time="([^"]+)"[^>]*Value="([^"]+)""#, false),
            (#"<EnumEvent[^>]*Value="([^"]+)"[^>]*Time="([^"]+)""#, true),
        ]
        let range = NSRange(eventsXML.startIndex..<eventsXML.endIndex, in: eventsXML)
        var parsed: [(beats: Double, enumValue: Int)] = []
        var seenEventKeys: Set<String> = []

        for (pattern, swapped) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: eventsXML, range: range) {
                guard match.numberOfRanges == 3,
                      let firstRange = Range(match.range(at: 1), in: eventsXML),
                      let secondRange = Range(match.range(at: 2), in: eventsXML) else {
                    continue
                }
                let timeString = swapped ? eventsXML[secondRange] : eventsXML[firstRange]
                let valueString = swapped ? eventsXML[firstRange] : eventsXML[secondRange]
                guard let beats = Double(timeString.replacingOccurrences(of: ",", with: ".")),
                      let enumValue = Int(valueString) else {
                    continue
                }
                let normalizedBeat = normalizeAbletonBeatTime(beats)
                let key = "\(normalizedBeat)|\(enumValue)"
                guard seenEventKeys.insert(key).inserted else { continue }
                parsed.append((beats: normalizedBeat, enumValue: enumValue))
            }
        }

        return parsed
    }

    private static func normalizeAbletonBeatTime(_ time: Double) -> Double {
        if time <= initialAutomationBeatThreshold {
            return 0
        }
        return max(0, time)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
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

private enum AbletonTimeSignatureEncoding {
    // Ableton stores arrangement time signatures as enum IDs on the master track.
    // IDs 200–225 are the classic Live preset list; 299–302 appear in Live 11.3+ sets.
    private static let table: [Int: (numerator: Int, denominator: Int)] = [
        200: (3, 4),
        201: (4, 4),
        202: (2, 4),
        203: (6, 4),
        204: (7, 4),
        205: (5, 4),
        206: (1, 4),
        207: (2, 2),
        208: (3, 2),
        209: (4, 2),
        210: (3, 8),
        211: (6, 8),
        212: (7, 8),
        213: (9, 8),
        214: (12, 8),
        215: (1, 8),
        216: (2, 8),
        217: (4, 8),
        218: (5, 8),
        219: (8, 8),
        220: (10, 8),
        221: (11, 8),
        222: (13, 8),
        223: (14, 8),
        224: (15, 8),
        225: (16, 8),
        // Live 11.3+ remaps preset meters to a higher enum ID range.
        299: (3, 8),
        300: (3, 8),
        301: (6, 8),
        302: (6, 8),
    ]

    static func decode(_ value: Int) -> (numerator: Int, denominator: Int)? {
        table[value]
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
