import XCTest
@testable import MultitrackLive

final class AudioTimelineMathTests: XCTestCase {
    func testQuantizeSnapsToNearestSampleBoundary() {
        let sampleRate = 48_000.0
        let oneSample = 1.0 / sampleRate

        // 2.5 samples should round away from zero to 3 samples.
        let input = oneSample * 2.5
        let expected = oneSample * 3.0

        XCTAssertEqual(
            AudioTimelineMath.quantize(input, sampleRate: sampleRate),
            expected,
            accuracy: 0.0000001
        )
    }

    func testQuantizeReturnsInputWhenSampleRateIsNonPositive() {
        let input: TimeInterval = 1.234
        XCTAssertEqual(AudioTimelineMath.quantize(input, sampleRate: 0), input, accuracy: 0.000001)
        XCTAssertEqual(AudioTimelineMath.quantize(input, sampleRate: -48000), input, accuracy: 0.000001)
    }
}

