import XCTest
@testable import MultitrackLive

final class AbletonProjectImporterTests: XCTestCase {
    func testImportsModernManualTempoAndLocators() throws {
        let xml = abletonXML(
            tempoBody: """
            <Manual Value="120" />
            <ArrangerAutomation>
              <Events>
                <FloatEvent Time="-63072000" Value="120" />
              </Events>
            </ArrangerAutomation>
            """,
            locators: [
                (name: "Intro", beats: 0),
                (name: "Verse", beats: 16),
            ]
        )

        let result = try AbletonProjectImporter.importFromXMLData(Data(xml.utf8))
        XCTAssertEqual(result.bpm, 120, accuracy: 0.001)
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.sections[0].name, "Intro")
        XCTAssertEqual(result.sections[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.sections[1].name, "Verse")
        XCTAssertEqual(result.sections[1].startSeconds, 8, accuracy: 0.001)
    }

    func testImportsLive8AutomationTempoWithoutManual() throws {
        let xml = abletonXML(
            tempoBody: """
            <ArrangerAutomation>
              <Events>
                <FloatEvent Time="-63072000" Value="71" />
                <FloatEvent Time="442" Value="71" />
                <FloatEvent Time="442" Value="67" />
                <FloatEvent Time="444" Value="71" />
              </Events>
            </ArrangerAutomation>
            """,
            locators: [
                (name: "Count Off", beats: 0),
                (name: "Intro", beats: 8),
                (name: "Verse 1", beats: 24),
            ]
        )

        let result = try AbletonProjectImporter.importFromXMLData(Data(xml.utf8))
        XCTAssertEqual(result.bpm, 71, accuracy: 0.001)
        XCTAssertEqual(result.sections.count, 3)
        XCTAssertEqual(result.sections[0].name, "Count Off")
        XCTAssertEqual(result.sections[1].name, "Intro")
        XCTAssertEqual(result.sections[1].startSeconds, 8 * 60.0 / 71.0, accuracy: 0.001)
        XCTAssertEqual(result.sections[2].name, "Verse 1")
    }

    func testPrefersManualTempoWhenAutomationAlsoPresent() throws {
        let xml = abletonXML(
            tempoBody: """
            <Manual Value="96" />
            <ArrangerAutomation>
              <Events>
                <FloatEvent Time="-63072000" Value="120" />
              </Events>
            </ArrangerAutomation>
            """,
            locators: [
                (name: "Start", beats: 0),
            ]
        )

        let result = try AbletonProjectImporter.importFromXMLData(Data(xml.utf8))
        XCTAssertEqual(result.bpm, 96, accuracy: 0.001)
    }

    func testImportsTempoAndTimeSignatureWithoutLocators() throws {
        let xml = abletonXML(
            tempoBody: """
            <Manual Value="79" />
            """,
            locators: [],
            timeSignatureManual: 201
        )

        let result = try AbletonProjectImporter.importFromXMLData(Data(xml.utf8))
        XCTAssertEqual(result.bpm, 79, accuracy: 0.001)
        XCTAssertTrue(result.sections.isEmpty)
        XCTAssertEqual(result.timeSignatures.count, 1)
        XCTAssertEqual(result.timeSignatures[0].numerator, 4)
        XCTAssertEqual(result.timeSignatures[0].denominator, 4)
        XCTAssertEqual(result.timeSignatures[0].startMeasure, 1)
    }

    func testImportsRealLive8MultitracksProject() throws {
        let url = URL(
            fileURLWithPath: NSString(
                string: "~/Downloads/This I Believe (The Creed)-No Other Name-B-71.00bpm/MultiTrack.als"
            ).expandingTildeInPath
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Sample Live 8 Multitracks project not present on this machine")
        }

        let result = try AbletonProjectImporter.importFrom(url: url)
        XCTAssertEqual(result.bpm, 71, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.sections.count, 20)
        XCTAssertEqual(result.sections.first?.name, "Count Off")
        XCTAssertTrue(result.sections.contains(where: { $0.name == "Intro" }))
        XCTAssertTrue(result.sections.contains(where: { $0.name == "Verse 1" }))
    }

    func testImportsRealLive11ProjectWithoutLocators() throws {
        let url = URL(
            fileURLWithPath: NSString(
                string: "~/Downloads/Files for testing/Small_E_79BPM68 Project/Small_E_79BPM68.als"
            ).expandingTildeInPath
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Sample Live 11 project without locators not present on this machine")
        }

        let result = try AbletonProjectImporter.importFrom(url: url)
        XCTAssertEqual(result.bpm, 79, accuracy: 0.001)
        XCTAssertTrue(result.sections.isEmpty)
        XCTAssertEqual(result.timeSignatures.first?.numerator, 4)
        XCTAssertEqual(result.timeSignatures.first?.denominator, 4)
    }

    private func abletonXML(
        tempoBody: String,
        locators: [(name: String, beats: Double)],
        timeSignatureManual: Int = 201
    ) -> String {
        let locatorXML = locators.map { locator in
            """
            <Locator>
              <Time Value="\(locator.beats)" />
              <Name Value="\(locator.name)" />
            </Locator>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <Ableton MajorVersion="4" MinorVersion="8.1_226" Creator="Ableton Live 8.4.2">
          <LiveSet>
            <MasterTrack>
              <DeviceChain>
                <Mixer>
                  <Tempo>
                    \(tempoBody)
                  </Tempo>
                  <TimeSignature>
                    <Manual Value="\(timeSignatureManual)" />
                    <ArrangerAutomation>
                      <Events>
                        <EnumEvent Time="-63072000" Value="\(timeSignatureManual)" />
                      </Events>
                    </ArrangerAutomation>
                  </TimeSignature>
                </Mixer>
              </DeviceChain>
            </MasterTrack>
            <Locators>
              <Locators>
                \(locatorXML)
              </Locators>
            </Locators>
          </LiveSet>
        </Ableton>
        """
    }
}
