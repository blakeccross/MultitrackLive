import XCTest
@testable import MultitrackLive

final class SongMusicalKeyTests: XCTestCase {
    func testTransposeWrapsUpThroughOctave() {
        XCTAssertEqual(SongMusicalKey.bFlat.transposed(by: 2), .c)
        XCTAssertEqual(SongMusicalKey.c.transposed(by: 12), .c)
        XCTAssertEqual(SongMusicalKey.g.transposed(by: 5), .c)
    }

    func testTransposeWrapsDownThroughOctave() {
        XCTAssertEqual(SongMusicalKey.c.transposed(by: -1), .b)
        XCTAssertEqual(SongMusicalKey.c.transposed(by: -12), .c)
        XCTAssertEqual(SongMusicalKey.f.transposed(by: -1), .e)
    }

    func testDisplayAppliesTransposeToBaseKey() {
        XCTAssertEqual(
            SongMusicalKey.display(baseRaw: "Bb", transposeSemitones: 2),
            "C"
        )
        XCTAssertEqual(
            SongMusicalKey.display(baseRaw: "C", transposeSemitones: -1),
            "B"
        )
        XCTAssertNil(SongMusicalKey.display(baseRaw: nil, transposeSemitones: 3))
        XCTAssertNil(SongMusicalKey.display(baseRaw: "H", transposeSemitones: 0))
    }

    func testTransportTextUsesEmDashWhenUnset() {
        XCTAssertEqual(
            SongMusicalKey.transportText(baseRaw: nil, transposeSemitones: 0),
            "—"
        )
        XCTAssertEqual(
            SongMusicalKey.transportText(baseRaw: "G", transposeSemitones: 0),
            "G"
        )
    }
}
