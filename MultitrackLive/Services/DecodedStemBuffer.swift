import AVFoundation
import Foundation

enum DecodedStemBufferError: Error {
    case unsupportedFormat
    case conversionFailed
    case emptyFile
    case pitchShiftFailed
}

/// Float32 PCM decoded once at load time for real-time memory playback.
final class DecodedStemBuffer: @unchecked Sendable {
    static let engineSampleRate: Double = 48_000

    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let audioFormat: AVAudioFormat

    private let channels: [UnsafeMutablePointer<Float>]

    private init(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        audioFormat: AVAudioFormat,
        channels: [UnsafeMutablePointer<Float>]
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.audioFormat = audioFormat
        self.channels = channels
    }

    deinit {
        for channel in channels {
            channel.deallocate()
        }
    }

    static func decode(
        from url: URL,
        targetSampleRate: Double = engineSampleRate
    ) throws -> DecodedStemBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let channelCount = Int(sourceFormat.channelCount)
        guard channelCount > 0 else { throw DecodedStemBufferError.unsupportedFormat }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw DecodedStemBufferError.unsupportedFormat
        }

        var channelArrays = Array(repeating: ContiguousArray<Float>(), count: channelCount)

        let canReadDirectly =
            sourceFormat.sampleRate == targetSampleRate
            && sourceFormat.commonFormat == .pcmFormatFloat32
            && !sourceFormat.isInterleaved

        if canReadDirectly {
            try readDirectly(from: file, channelCount: channelCount, into: &channelArrays)
        } else {
            try convertIntoMemory(
                from: file,
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                channelCount: channelCount,
                into: &channelArrays
            )
        }

        guard let firstChannel = channelArrays.first, !firstChannel.isEmpty else {
            throw DecodedStemBufferError.emptyFile
        }

        let frameCount = firstChannel.count
        let channelPointers = channelArrays.map { array -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            array.withUnsafeBufferPointer { buffer in
                pointer.initialize(from: buffer.baseAddress!, count: frameCount)
            }
            return pointer
        }

        return DecodedStemBuffer(
            sampleRate: targetSampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            audioFormat: targetFormat,
            channels: channelPointers
        )
    }

    func applyingSemitoneShift(_ semitones: Int) throws -> DecodedStemBuffer {
        try RubberBandPitchProcessor.pitchShift(buffer: self, semitones: semitones)
    }

    func channelPointer(_ channel: Int) -> UnsafePointer<Float> {
        UnsafePointer(channels[channel])
    }

    static func fromPitchShiftResult(
        _ result: PitchShiftResult,
        sampleRate: Double,
        audioFormat: AVAudioFormat
    ) throws -> DecodedStemBuffer {
        let channelCount = Int(result.channelCount)
        let frameCount = Int(result.frameCount)
        guard channelCount > 0, frameCount > 0, let sourceChannels = result.channels else {
            throw DecodedStemBufferError.pitchShiftFailed
        }

        var channelPointers: [UnsafeMutablePointer<Float>] = []
        channelPointers.reserveCapacity(channelCount)

        for channel in 0..<channelCount {
            guard let sourceChannel = sourceChannels[channel] else {
                throw DecodedStemBufferError.pitchShiftFailed
            }
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            pointer.initialize(from: sourceChannel, count: frameCount)
            channelPointers.append(pointer)
        }

        return DecodedStemBuffer(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            audioFormat: audioFormat,
            channels: channelPointers
        )
    }

    func copy(
        channel: Int,
        startingFrame: Int,
        frameCount requestedFrames: Int,
        into destination: UnsafeMutablePointer<Float>,
        destinationOffset: Int,
        gain: Float
    ) -> Int {
        guard channel >= 0, channel < channelCount else { return 0 }
        guard startingFrame >= 0, startingFrame < frameCount else { return 0 }

        let available = min(requestedFrames, frameCount - startingFrame)
        guard available > 0 else { return 0 }

        let source = channels[channel].advanced(by: startingFrame)
        let destinationPointer = destination.advanced(by: destinationOffset)

        if gain == 1 {
            destinationPointer.update(from: source, count: available)
        } else {
            for index in 0..<available {
                destinationPointer[index] = source[index] * gain
            }
        }

        return available
    }

    private static func readDirectly(
        from file: AVAudioFile,
        channelCount: Int,
        into channelArrays: inout [ContiguousArray<Float>]
    ) throws {
        let chunkFrames: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ), let channelData = buffer.floatChannelData else {
            throw DecodedStemBufferError.unsupportedFormat
        }

        file.framePosition = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let readCount = min(chunkFrames, remaining)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: readCount)

            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }

            for channel in 0..<channelCount {
                channelArrays[channel].append(contentsOf: UnsafeBufferPointer(
                    start: channelData[channel],
                    count: framesRead
                ))
            }
        }
    }

    private static func convertIntoMemory(
        from file: AVAudioFile,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        channelCount: Int,
        into channelArrays: inout [ContiguousArray<Float>]
    ) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw DecodedStemBufferError.conversionFailed
        }

        let inputChunkFrames: AVAudioFrameCount = 8_192
        let outputChunkFrames: AVAudioFrameCount = 8_192

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: inputChunkFrames
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputChunkFrames
        ), let outputChannels = outputBuffer.floatChannelData else {
            throw DecodedStemBufferError.conversionFailed
        }

        file.framePosition = 0
        var inputFinished = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputFinished {
                outStatus.pointee = .noDataNow
                return nil
            }

            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            if remaining == 0 {
                outStatus.pointee = .endOfStream
                inputFinished = true
                return nil
            }

            let readCount = min(inputChunkFrames, remaining)
            inputBuffer.frameLength = 0

            do {
                try file.read(into: inputBuffer, frameCount: readCount)
            } catch {
                outStatus.pointee = .endOfStream
                inputFinished = true
                return nil
            }

            if inputBuffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                inputFinished = true
                return nil
            }

            outStatus.pointee = .haveData
            return inputBuffer
        }

        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError,
                withInputFrom: inputBlock
            )

            if let conversionError {
                throw conversionError
            }

            let framesConverted = Int(outputBuffer.frameLength)
            if framesConverted > 0 {
                for channel in 0..<channelCount {
                    channelArrays[channel].append(contentsOf: UnsafeBufferPointer(
                        start: outputChannels[channel],
                        count: framesConverted
                    ))
                }
            }

            if status == .endOfStream, framesConverted == 0 {
                break
            }
        }
    }
}
