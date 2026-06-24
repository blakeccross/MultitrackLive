import Foundation

enum ClickTrackGeneratorError: Error {
    case missingAccentSample
    case missingNormalSample
    case invalidDuration
}

enum ClickTrackGenerator {
    private static let sampleRate = DecodedStemBuffer.engineSampleRate
    private static let bundleSubdirectory = "Click"
    private static let accentResourceName = "click-accent"
    private static let normalResourceName = "click-normal"

    private static var cachedAccent: DecodedStemBuffer?
    private static var cachedNormal: DecodedStemBuffer?

    static func generate(
        duration: TimeInterval,
        tempoChanges: [TempoChange],
        timeSignatureChanges: [TimeSignatureChange],
        subdivision: ClickTrackSubdivision = .quarter,
        accent: DecodedStemBuffer? = nil,
        normal: DecodedStemBuffer? = nil
    ) throws -> DecodedStemBuffer {
        guard duration > 0 else { throw ClickTrackGeneratorError.invalidDuration }

        let normalizedTempo = tempoChanges.normalizedEnsuringInitialMarker(
            defaultBPM: tempoChanges.referenceBPM
        )
        let normalizedSignatures = timeSignatureChanges.normalizedEnsuringInitialMarker(
            defaultNumerator: MeasureTiming.defaultNumerator,
            defaultDenominator: MeasureTiming.defaultDenominator
        )

        let frameCount = Int((duration * sampleRate).rounded(.up))
        let output = try DecodedStemBuffer.silent(frameCount: frameCount, sampleRate: sampleRate)

        let accentSample = try accent ?? sharedAccentSample()
        let normalSample = try normal ?? sharedNormalSample()

        let clicks = ClickTrackScheduler.scheduledClicks(
            from: 0,
            to: duration,
            tempoChanges: normalizedTempo,
            timeSignatureChanges: normalizedSignatures,
            subdivision: subdivision
        )

        for click in clicks {
            let sample = click.isAccent ? accentSample : normalSample
            let startFrame = Int((click.time * sampleRate).rounded())
            output.mixAdding(sample, atFrame: startFrame)
        }

        return output
    }

    static func sharedAccentSample() throws -> DecodedStemBuffer {
        try accentSample()
    }

    static func sharedNormalSample() throws -> DecodedStemBuffer {
        try normalSample()
    }

    static func resetCachedSamples() {
        cachedAccent = nil
        cachedNormal = nil
    }

    static func loadSample(named resourceName: String) throws -> DecodedStemBuffer {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "wav",
            subdirectory: bundleSubdirectory
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: "wav") else {
            if resourceName == accentResourceName {
                throw ClickTrackGeneratorError.missingAccentSample
            }
            throw ClickTrackGeneratorError.missingNormalSample
        }
        return try DecodedStemBuffer.decode(from: url)
    }

    private static func accentSample() throws -> DecodedStemBuffer {
        if let cachedAccent { return cachedAccent }
        let sample = try loadSample(named: accentResourceName)
        cachedAccent = sample
        return sample
    }

    private static func normalSample() throws -> DecodedStemBuffer {
        if let cachedNormal { return cachedNormal }
        let sample = try loadSample(named: normalResourceName)
        cachedNormal = sample
        return sample
    }
}
