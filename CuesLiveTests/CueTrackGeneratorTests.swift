import XCTest
@testable import CuesLive

final class CueTrackGeneratorTests: XCTestCase {
    private let sampleRate = DecodedStemBuffer.engineSampleRate

    func testPlacesSpeechSampleAtAnnounceTime() throws {
        let speech = try DecodedStemBuffer.impulseSample(frameCount: 10, peakFrame: 0, amplitude: 1)

        let buffer = try CueTrackGenerator.generate(
            duration: 4,
            announcements: [
                CueAnnouncement(name: "Verse", announceTime: 2, boundaryTime: 4)
            ],
            speechBuffers: ["Verse": speech]
        )

        let peaks = peakTimes(in: buffer)
        XCTAssertEqual(peaks.count, 1)
        XCTAssertEqual(peaks[0], 2, accuracy: 0.001)
    }

    func testThrowsWhenSpeechSampleMissing() {
        XCTAssertThrowsError(
            try CueTrackGenerator.generate(
                duration: 2,
                announcements: [
                    CueAnnouncement(name: "Chorus", announceTime: 0, boundaryTime: 2)
                ],
                speechBuffers: [:]
            )
        )
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
