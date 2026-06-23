import XCTest
@testable import MultitrackLive

final class ClickTrackGeneratorTests: XCTestCase {
    private let sampleRate = DecodedStemBuffer.engineSampleRate

    func testFourFourAt120BPMPlacesQuarterNoteClicks() throws {
        let accent = try DecodedStemBuffer.impulseSample()
        let normal = try DecodedStemBuffer.impulseSample()

        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let buffer = try ClickTrackGenerator.generate(
            duration: 2,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            accent: accent,
            normal: normal
        )

        let beatTimes = peakTimes(in: buffer)
        XCTAssertEqual(beatTimes.count, 4)
        XCTAssertEqual(beatTimes[0], 0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(beatTimes[2], 1.0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[3], 1.5, accuracy: 0.001)
    }

    func testThreeFourTimeSignatureUsesThreeBeatsPerMeasure() throws {
        let accent = try DecodedStemBuffer.impulseSample()
        let normal = try DecodedStemBuffer.impulseSample()

        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 3, denominator: 4, startMeasure: 1)]

        let buffer = try ClickTrackGenerator.generate(
            duration: 2,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            accent: accent,
            normal: normal
        )

        let beatTimes = peakTimes(in: buffer)
        XCTAssertEqual(beatTimes.count, 4)
        XCTAssertEqual(beatTimes[0], 0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(beatTimes[2], 1.0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[3], 1.5, accuracy: 0.001)
    }

    func testTempoChangeAdjustsLaterBeatSpacing() throws {
        let accent = try DecodedStemBuffer.impulseSample()
        let normal = try DecodedStemBuffer.impulseSample()

        let tempoChanges = [
            TempoChange(startMeasure: 1, bpm: 120),
            TempoChange(startMeasure: 3, bpm: 60),
        ]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let buffer = try ClickTrackGenerator.generate(
            duration: 8,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            accent: accent,
            normal: normal
        )

        let beatTimes = peakTimes(in: buffer)
        XCTAssertGreaterThanOrEqual(beatTimes.count, 10)
        XCTAssertEqual(beatTimes[0], 0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(beatTimes[4], 2.0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[8], 4.0, accuracy: 0.001)
        XCTAssertEqual(beatTimes[9], 5.0, accuracy: 0.001)
    }

    func testEighthNoteSubdivisionDoublesClickDensity() throws {
        let accent = try DecodedStemBuffer.impulseSample()
        let normal = try DecodedStemBuffer.impulseSample()

        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let buffer = try ClickTrackGenerator.generate(
            duration: 1,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            subdivision: .eighth,
            accent: accent,
            normal: normal
        )

        let clickTimes = peakTimes(in: buffer, minimumSpacing: 0.05)
        XCTAssertEqual(clickTimes.count, 4)
        XCTAssertEqual(clickTimes[0], 0, accuracy: 0.001)
        XCTAssertEqual(clickTimes[1], 0.25, accuracy: 0.001)
        XCTAssertEqual(clickTimes[2], 0.5, accuracy: 0.001)
        XCTAssertEqual(clickTimes[3], 0.75, accuracy: 0.001)
    }

    func testSixteenthNoteSubdivisionQuadruplesClickDensity() throws {
        let accent = try DecodedStemBuffer.impulseSample()
        let normal = try DecodedStemBuffer.impulseSample()

        let tempoChanges = [TempoChange(startMeasure: 1, bpm: 120)]
        let timeSignatures = [TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)]

        let buffer = try ClickTrackGenerator.generate(
            duration: 0.5,
            tempoChanges: tempoChanges,
            timeSignatureChanges: timeSignatures,
            subdivision: .sixteenth,
            accent: accent,
            normal: normal
        )

        let clickTimes = peakTimes(in: buffer, minimumSpacing: 0.03)
        XCTAssertEqual(clickTimes.count, 4)
        XCTAssertEqual(clickTimes[0], 0, accuracy: 0.001)
        XCTAssertEqual(clickTimes[1], 0.125, accuracy: 0.001)
        XCTAssertEqual(clickTimes[2], 0.25, accuracy: 0.001)
        XCTAssertEqual(clickTimes[3], 0.375, accuracy: 0.001)
    }

    private func peakTimes(in buffer: DecodedStemBuffer, threshold: Float = 0.5, minimumSpacing: TimeInterval = 0.1) -> [TimeInterval] {
        var peaks: [TimeInterval] = []

        for frame in 0..<buffer.frameCount {
            let sample = abs(buffer.interpolatedSample(channel: 0, frame: Double(frame)))
            guard sample >= threshold else { continue }

            let time = Double(frame) / sampleRate
            if peaks.last.map({ time - $0 > minimumSpacing }) ?? true {
                peaks.append(time)
            }
        }

        return peaks
    }
}
