import XCTest
@testable import CuesLive

final class LTCFrameEncoderTests: XCTestCase {
    func testSyncWordBitsMatchLibLTCPattern() {
        let bits = LTCFrameEncoder.bits(
            for: TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 0),
            frameRate: .fps30
        )

        var sync: UInt16 = 0
        for offset in 0..<16 {
            if bits[64 + offset] {
                sync |= (1 << offset)
            }
        }
        XCTAssertEqual(sync, LTCFrameEncoder.syncWord)
    }

    func testEncodesBCDTimeFields() {
        let bits = LTCFrameEncoder.bits(
            for: TimecodeValue(hours: 12, minutes: 34, seconds: 56, frames: 7),
            frameRate: .fps30
        )

        XCTAssertEqual(bcd(bits, start: 0, count: 4), 7) // frames units
        XCTAssertEqual(bcd(bits, start: 8, count: 2), 0) // frames tens
        XCTAssertEqual(bcd(bits, start: 16, count: 4), 6) // seconds units
        XCTAssertEqual(bcd(bits, start: 24, count: 3), 5) // seconds tens
        XCTAssertEqual(bcd(bits, start: 32, count: 4), 4) // minutes units
        XCTAssertEqual(bcd(bits, start: 40, count: 3), 3) // minutes tens
        XCTAssertEqual(bcd(bits, start: 48, count: 4), 2) // hours units
        XCTAssertEqual(bcd(bits, start: 56, count: 2), 1) // hours tens
    }

    func testDropFrameFlagSetOnlyForDropFrameRate() {
        let nondrop = LTCFrameEncoder.bits(
            for: .atHour(1),
            frameRate: .fps30
        )
        let drop = LTCFrameEncoder.bits(
            for: .atHour(1),
            frameRate: .fps2997Drop
        )
        XCTAssertFalse(nondrop[10])
        XCTAssertTrue(drop[10])
    }

    func testParityMakesZeroCountEvenForThirtyFPS() {
        let bits = LTCFrameEncoder.bits(
            for: TimecodeValue(hours: 1, minutes: 2, seconds: 3, frames: 4),
            frameRate: .fps30
        )
        let zeroCount = bits.reduce(0) { $0 + ($1 ? 0 : 1) }
        XCTAssertEqual(zeroCount % 2, 0)
    }

    private func bcd(_ bits: [Bool], start: Int, count: Int) -> Int {
        var value = 0
        for offset in 0..<count where bits[start + offset] {
            value |= (1 << offset)
        }
        return value
    }
}
