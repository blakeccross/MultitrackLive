import Foundation

enum LTCGeneratorError: Error {
    case invalidDuration
}

enum LTCGenerator {
    /// Approx −9 dBFS square amplitude for reliable desk lock.
    static let amplitude: Float = 0.35

    static func generate(
        duration: TimeInterval,
        start: TimecodeValue,
        frameRate: TimecodeFrameRate,
        sampleRate: Double = DecodedStemBuffer.engineSampleRate,
        amplitude: Float = amplitude
    ) throws -> DecodedStemBuffer {
        guard duration > 0, sampleRate > 0 else {
            throw LTCGeneratorError.invalidDuration
        }

        let frameCount = max(1, Int((duration * sampleRate).rounded(.toNearestOrAwayFromZero)))
        let output = try DecodedStemBuffer.silent(frameCount: frameCount, sampleRate: sampleRate)
        let samplesPerTimecodeFrame = sampleRate / frameRate.framesPerSecond
        guard samplesPerTimecodeFrame > 1 else {
            throw LTCGeneratorError.invalidDuration
        }

        let samplesPerBit = samplesPerTimecodeFrame / 80.0
        var phasePositive = true
        var frameOrdinal = 0
        var timecode = start

        output.withMutableSamples(channel: 0) { samples, count in
            while true {
                let frameStart = Int((Double(frameOrdinal) * samplesPerTimecodeFrame).rounded(.down))
                if frameStart >= count {
                    break
                }

                let bits = LTCFrameEncoder.bits(for: timecode, frameRate: frameRate)
                for bitIndex in 0..<80 {
                    // Bi-phase mark: transition at every bit boundary.
                    phasePositive.toggle()
                    let bitStart = frameStart + Int((Double(bitIndex) * samplesPerBit).rounded(.down))
                    let bitMid = frameStart + Int(((Double(bitIndex) + 0.5) * samplesPerBit).rounded(.down))
                    let bitEnd = frameStart + Int(((Double(bitIndex) + 1.0) * samplesPerBit).rounded(.down))

                    fill(
                        samples,
                        count: count,
                        from: bitStart,
                        to: bits[bitIndex] ? bitMid : bitEnd,
                        value: phasePositive ? amplitude : -amplitude
                    )

                    if bits[bitIndex] {
                        phasePositive.toggle()
                        fill(
                            samples,
                            count: count,
                            from: bitMid,
                            to: bitEnd,
                            value: phasePositive ? amplitude : -amplitude
                        )
                    }
                }

                frameOrdinal += 1
                timecode = start.advanced(byFrames: frameOrdinal, frameRate: frameRate)
            }
        }

        return output
    }

    private static func fill(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int,
        from start: Int,
        to end: Int,
        value: Float
    ) {
        let clampedStart = max(0, start)
        let clampedEnd = min(count, end)
        guard clampedStart < clampedEnd else { return }
        for frame in clampedStart..<clampedEnd {
            samples[frame] = value
        }
    }
}
