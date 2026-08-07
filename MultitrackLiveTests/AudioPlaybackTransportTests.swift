import XCTest
@testable import MultitrackLive

final class AudioPlaybackTransportTests: XCTestCase {
    func testMappedTimelineAppliesPendingTransitionAtCorrectPoint() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)

        // Before transition.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 2.5), 2.5, accuracy: 0.0000001)

        // Exactly at transition start: jumps to targetOffset.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 3.0), 2.0, accuracy: 0.0000001)

        // After transition: continues forward from the target offset.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 4.0), 3.0, accuracy: 0.0000001)
    }

    func testMappedTimelineClampsToDuration() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)

        XCTAssertEqual(transport.mappedTimeline(fromLinear: 12.0), 10.0, accuracy: 0.0000001)
    }

    func testCancelScheduledTransitionClearsMapping() {
        let transport = AudioPlaybackTransport()
        transport.setDuration(10)
        transport.scheduleTransition(to: 2, at: 3)
        transport.cancelScheduledTransition()

        // Without a pending transition, mapping should return the raw linear value.
        XCTAssertEqual(transport.mappedTimeline(fromLinear: 4.0), 4.0, accuracy: 0.0000001)
    }

    func testWrappedTimelineLoopsIntoHalfOpenRange() {
        let loop = AudioPlaybackTransport.LoopRegion(start: 0, end: 16)
        let sampleRate = DecodedStemBuffer.engineSampleRate

        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(0, loop: loop, sampleRate: sampleRate),
            0,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(15.999, loop: loop, sampleRate: sampleRate),
            15.999,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(16, loop: loop, sampleRate: sampleRate),
            0,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(16.25, loop: loop, sampleRate: sampleRate),
            0.25,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(32, loop: loop, sampleRate: sampleRate),
            0,
            accuracy: 0.0000001
        )
    }

    func testWrappedTimelineSupportsInteriorSectionLoops() {
        let loop = AudioPlaybackTransport.LoopRegion(start: 4, end: 8)
        let sampleRate = DecodedStemBuffer.engineSampleRate

        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(3.5, loop: loop, sampleRate: sampleRate),
            3.5,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(8, loop: loop, sampleRate: sampleRate),
            4,
            accuracy: 0.0000001
        )
        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(9.5, loop: loop, sampleRate: sampleRate),
            5.5,
            accuracy: 0.0000001
        )
    }

    func testFrameIndexKeepsSubSampleOffsetsOnSameFrame() {
        let sampleRate = 48_000.0

        XCTAssertEqual(AudioPlaybackTransport.frameIndex(for: 0, sampleRate: sampleRate), 0)
        XCTAssertEqual(
            AudioPlaybackTransport.frameIndex(for: 0.5 / sampleRate, sampleRate: sampleRate),
            0
        )
        XCTAssertEqual(
            AudioPlaybackTransport.frameIndex(for: 0.999 / sampleRate, sampleRate: sampleRate),
            0
        )
        XCTAssertEqual(
            AudioPlaybackTransport.frameIndex(for: 1.0 / sampleRate, sampleRate: sampleRate),
            1
        )
    }

    func testWrappedTimelineSnapsJustPastEndOntoFrameZero() {
        let loop = AudioPlaybackTransport.LoopRegion(start: 0, end: 16)
        let sampleRate = 48_000.0
        let justPastEnd = 16.0 + 0.25 / sampleRate

        XCTAssertEqual(
            AudioPlaybackTransport.wrappedTimeline(justPastEnd, loop: loop, sampleRate: sampleRate),
            0,
            accuracy: 0.0000001
        )
    }

    func testLoopedFrameZeroIsAudibleOnEveryIteration() {
        let sampleRate = 48_000.0
        let loopEnd = 16.0
        let endFrame = AudioPlaybackTransport.frameIndex(for: loopEnd, sampleRate: sampleRate)
        let loop = AudioPlaybackTransport.LoopRegion(start: 0, end: loopEnd)

        // Exact loop boundary and each subsequent iteration must map to frame 0
        // so the downbeat click is included like a DAW audio loop.
        for iteration in 0..<4 {
            let absolute = Double(endFrame * iteration) / sampleRate
            let wrapped = AudioPlaybackTransport.wrappedTimeline(
                absolute,
                loop: loop,
                sampleRate: sampleRate
            )
            XCTAssertEqual(
                AudioPlaybackTransport.frameIndex(for: wrapped, sampleRate: sampleRate),
                0,
                "iteration \(iteration) should land on frame 0"
            )
        }
    }

    func testFrameSpanKeepsTheFinalFrameOfARegion() {
        let sampleRate = 48_000.0

        // Region lengths are computed as `sectionEnd - master`, which is not exactly
        // representable. Flooring the raw product yields 0 here and silences the top
        // of a loop, because the render loop stops as soon as a run is empty.
        for sectionEnd in [8.0, 16.0, 33.0, 104.0, 200.0] {
            let lastFrame = AudioPlaybackTransport.frameIndex(for: sectionEnd, sampleRate: sampleRate) - 1
            let remaining = sectionEnd - (Double(lastFrame) / sampleRate)

            XCTAssertEqual(
                AudioPlaybackTransport.frameSpan(forSeconds: remaining, sampleRate: sampleRate),
                1,
                "section ending at \(sectionEnd)s must still render its final frame"
            )
        }
    }

    func testFrameSpanIsZeroOnlyForEmptyRegions() {
        let sampleRate = 48_000.0

        XCTAssertEqual(AudioPlaybackTransport.frameSpan(forSeconds: 0, sampleRate: sampleRate), 0)
        XCTAssertEqual(AudioPlaybackTransport.frameSpan(forSeconds: -1, sampleRate: sampleRate), 0)
        XCTAssertEqual(
            AudioPlaybackTransport.frameSpan(forSeconds: 0.4 / sampleRate, sampleRate: sampleRate),
            0
        )
        XCTAssertEqual(
            AudioPlaybackTransport.frameSpan(forSeconds: 1.9 / sampleRate, sampleRate: sampleRate),
            1
        )
        XCTAssertEqual(
            AudioPlaybackTransport.frameSpan(forSeconds: 0.5, sampleRate: sampleRate),
            24_000
        )
    }

    func testTempoMapContinuesPastSongDurationForLooping() {
        let extendingMap = TempoPlaybackMap.build(
            tempoChanges: [TempoChange(startMeasure: 1, bpm: 120)],
            referenceBPM: 120,
            timeSignatureChanges: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)
            ],
            maxSourceTime: TempoPlaybackMap.defaultMaxSourceTime
        )
        let pastEnd = extendingMap.sourceTimeAfterWallElapsed(from: 15, wallElapsed: 2)
        XCTAssertGreaterThan(
            pastEnd,
            16.5,
            "Tempo map must advance past song duration so loops are not frozen on frame 0"
        )

        // Reproduce the previous bug: capping maxSourceTime at song duration.
        let cappedMap = TempoPlaybackMap.build(
            tempoChanges: [TempoChange(startMeasure: 1, bpm: 120)],
            referenceBPM: 120,
            timeSignatureChanges: [
                TimeSignatureChange(numerator: 4, denominator: 4, startMeasure: 1)
            ],
            maxSourceTime: 16
        )
        let stuck = cappedMap.sourceTimeAfterWallElapsed(from: 15, wallElapsed: 2)
        XCTAssertEqual(stuck, 16, accuracy: 0.001)
    }
}

