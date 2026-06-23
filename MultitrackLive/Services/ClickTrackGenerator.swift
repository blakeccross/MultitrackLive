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

        let accentSample = try accent ?? accentSample()
        let normalSample = try normal ?? normalSample()
        let subdivisionsPerBeat = subdivision.subdivisionsPerBeat

        var measure = 1
        while true {
            let measureStart = MeasureTiming.timeAtStartOfMeasure(
                measure,
                tempoChanges: normalizedTempo,
                timeSignatureChanges: normalizedSignatures
            )
            if measureStart >= duration { break }

            let bpm = MeasureTiming.bpmForMeasure(measure, tempoChanges: normalizedTempo)
            guard bpm > 0 else { break }

            let signature = MeasureTiming.numeratorDenominatorForMeasure(
                measure,
                changes: normalizedSignatures
            )
            let beatsInMeasure = Int(
                MeasureTiming.beatsPerMeasure(
                    numerator: signature.numerator,
                    denominator: signature.denominator
                ).rounded(.down)
            )
            let beatDuration = 60.0 / bpm
            let subdivisionDuration = beatDuration / Double(subdivisionsPerBeat)
            let subdivisionsInMeasure = max(1, beatsInMeasure) * subdivisionsPerBeat

            for subdivisionIndex in 0..<subdivisionsInMeasure {
                let clickTime = measureStart + TimeInterval(subdivisionIndex) * subdivisionDuration
                if clickTime >= duration { break }

                let sample = subdivisionIndex == 0 ? accentSample : normalSample
                let startFrame = Int((clickTime * sampleRate).rounded())
                output.mixAdding(sample, atFrame: startFrame)
            }

            measure += 1
            if measure > 1_000_000 { break }
        }

        return output
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
