import XCTest
@testable import MultitrackLive

final class SongSectionNameNormalizerTests: XCTestCase {
    func testVerseVariantsCanonicalizeToVerse1() {
        let variants = ["V1", "V 1", "Verse1", "verse 1", "VERSE 1"]
        for variant in variants {
            XCTAssertEqual(
                SongSectionNameNormalizer.canonicalize(variant),
                "Verse 1",
                "Expected \(variant) to become Verse 1"
            )
        }
    }

    func testIntroVariantsCanonicalizeToIntro() {
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("INTRO"), "Intro")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("intro"), "Intro")
    }

    func testPreChorusVariantsCanonicalizeToPreChorus() {
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("PC"), "Pre-Chorus")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("PreChorus"), "Pre-Chorus")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("pre chorus"), "Pre-Chorus")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("Pre_Chorus"), "Pre-Chorus")
    }

    func testUnmatchedNamesRemainUnchanged() {
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("My Cue"), "My Cue")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("Section 2"), "Section 2")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("Start"), "Start")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("Verse 4"), "Verse 4")
    }

    func testEmptyNameStaysEmpty() {
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize(""), "")
        XCTAssertEqual(SongSectionNameNormalizer.canonicalize("   "), "")
    }

    func testAbletonImportAppliesCanonicalization() {
        let result = AbletonProjectImporter.ImportResult(
            bpm: 120,
            sections: [
                (name: "V1", startSeconds: 0),
                (name: "INTRO", startSeconds: 16),
                (name: "PC", startSeconds: 32),
                (name: "My Cue", startSeconds: 48),
            ],
            timeSignatures: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1, sortOrder: 0),
            ]
        )

        let markers = AbletonProjectImporter.makeMarkers(from: result)

        XCTAssertEqual(markers.count, 4)
        XCTAssertEqual(markers[0].name, "Verse 1")
        XCTAssertEqual(markers[1].name, "Intro")
        XCTAssertEqual(markers[2].name, "Pre-Chorus")
        XCTAssertEqual(markers[3].name, "My Cue")
    }
}
