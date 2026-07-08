import AVFoundation
import Foundation
import os

enum DecodedStemBufferError: Error {
    case unsupportedFormat
    case conversionFailed
    case emptyFile
    case pitchShiftFailed
}

/// Real-time sample provider for one track. Both the fully-in-memory
/// `DecodedStemBuffer` and the disk-streaming `StreamingStemBuffer` conform,
/// so the render path can read samples without knowing the backing storage.
protocol StemSampleSource: AnyObject, Sendable {
    var sampleRate: Double { get }
    var channelCount: Int { get }
    var frameCount: Int { get }
    var audioFormat: AVAudioFormat { get }

    @discardableResult
    func copy(
        channel: Int,
        startingFrame: Int,
        frameCount: Int,
        into destination: UnsafeMutablePointer<Float>,
        destinationOffset: Int,
        gain: Float
    ) -> Int

    func interpolatedSample(channel: Int, frame: Double) -> Float

    /// Hint that playback is about to read near `frame`; streaming sources use
    /// this to warm their look-ahead window. In-memory sources ignore it.
    func prewarm(aroundSourceFrame frame: Int)
}

extension StemSampleSource {
    func prewarm(aroundSourceFrame frame: Int) {}
}

/// Float32 PCM decoded once at load time for real-time memory playback.
final class DecodedStemBuffer: StemSampleSource, @unchecked Sendable {
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
        from data: Data,
        targetSampleRate: Double = engineSampleRate
    ) throws -> DecodedStemBuffer {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("wav")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try decode(from: tempURL, targetSampleRate: targetSampleRate)
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

    func mutableChannelPointer(_ channel: Int) -> UnsafeMutablePointer<Float> {
        channels[channel]
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

    func interpolatedSample(channel: Int, frame: Double) -> Float {
        guard channel >= 0, channel < channelCount, frameCount > 0 else { return 0 }
        guard frame >= 0 else { return 0 }

        if frame >= Double(frameCount - 1) {
            return channels[channel][frameCount - 1]
        }

        let index = Int(floor(frame))
        let fraction = Float(frame - Double(index))
        let sampleA = channels[channel][index]
        let sampleB = channels[channel][index + 1]
        return sampleA + (sampleB - sampleA) * fraction
    }

    static func silent(
        frameCount: Int,
        sampleRate: Double = engineSampleRate,
        channelCount: Int = 1
    ) throws -> DecodedStemBuffer {
        guard frameCount > 0, channelCount > 0 else {
            throw DecodedStemBufferError.emptyFile
        }
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw DecodedStemBufferError.unsupportedFormat
        }

        var channelPointers: [UnsafeMutablePointer<Float>] = []
        channelPointers.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            pointer.initialize(repeating: 0, count: frameCount)
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

    func mixAdding(_ sample: DecodedStemBuffer, atFrame startFrame: Int) {
        let channelsToMix = min(channelCount, sample.channelCount)
        guard channelsToMix > 0, startFrame >= 0 else { return }

        for channel in 0..<channelsToMix {
            let destination = channels[channel]
            let source = sample.channels[channel]
            let available = min(sample.frameCount, frameCount - startFrame)
            guard available > 0 else { continue }

            for index in 0..<available {
                destination[startFrame + index] += source[index]
            }
        }
    }

    static func impulseSample(
        frameCount: Int = 100,
        peakFrame: Int = 0,
        amplitude: Float = 1.0,
        sampleRate: Double = engineSampleRate
    ) throws -> DecodedStemBuffer {
        let buffer = try silent(frameCount: frameCount, sampleRate: sampleRate)
        guard peakFrame >= 0, peakFrame < frameCount else { return buffer }
        buffer.channels[0][peakFrame] = amplitude
        return buffer
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

/// Disk-streaming sample provider. Instead of decoding an entire stem into RAM,
/// it keeps a bounded sliding window of decoded pages around the playhead. A
/// background timer reads ahead from the file so the real-time render thread
/// only ever reads already-resident pages (never touching disk).
final class StreamingStemBuffer: StemSampleSource, @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let audioFormat: AVAudioFormat

    private final class Page {
        let channels: [UnsafeMutablePointer<Float>]
        let validFrames: Int

        init(channelCount: Int, capacity: Int, validFrames: Int) {
            self.validFrames = validFrames
            channels = (0..<channelCount).map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                pointer.initialize(repeating: 0, count: capacity)
                return pointer
            }
        }

        deinit { channels.forEach { $0.deallocate() } }
    }

    private let pageFrames: Int
    private let lookAheadPages: Int
    private let lookBehindPages: Int

    // Resident pages, guarded by `pageLock`. Touched by both render and reader.
    private var pages: [Int: Page] = [:]
    private var pageLock = os_unfair_lock()

    // Latest source frame the render thread asked for, guarded by `centerLock`.
    private var requestedCenterFrame = 0
    private var centerLock = os_unfair_lock()

    // File + scratch buffer are ONLY ever used on `readerQueue`.
    private let readerQueue = DispatchQueue(label: "StreamingStemBuffer.reader", qos: .userInitiated)
    private let reader: AVAudioFile
    private let readBuffer: AVAudioPCMBuffer
    private var timer: DispatchSourceTimer?

    init(
        url: URL,
        pageFrames: Int = 16_384,
        lookAheadSeconds: Double = 6,
        lookBehindSeconds: Double = 1
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0, file.length > 0 else {
            throw DecodedStemBufferError.emptyFile
        }
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(pageFrames)
        ) else {
            throw DecodedStemBufferError.unsupportedFormat
        }

        reader = file
        readBuffer = scratch
        audioFormat = format
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        frameCount = Int(file.length)
        self.pageFrames = pageFrames
        lookAheadPages = max(1, Int((lookAheadSeconds * format.sampleRate / Double(pageFrames)).rounded(.up)))
        lookBehindPages = max(0, Int((lookBehindSeconds * format.sampleRate / Double(pageFrames)).rounded(.up)))

        startReaderTimer()
    }

    deinit {
        timer?.cancel()
        timer = nil
        pages.removeAll()
    }

    func prewarm(aroundSourceFrame frame: Int) {
        let clamped = max(0, min(frame, max(0, frameCount - 1)))
        os_unfair_lock_lock(&centerLock)
        requestedCenterFrame = clamped
        os_unfair_lock_unlock(&centerLock)
        readerQueue.sync { self.fillWindow(around: clamped) }
    }

    @discardableResult
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

        noteRequested(frame: startingFrame)

        var written = 0
        os_unfair_lock_lock(&pageLock)
        while written < available {
            let globalFrame = startingFrame + written
            let pageIndex = globalFrame / pageFrames
            let offsetInPage = globalFrame % pageFrames
            let spanToPageEnd = min(pageFrames - offsetInPage, available - written)

            // Copy whatever of this page span is resident; the rest stays silent
            // (the destination is pre-zeroed by the caller before mixing).
            if let page = pages[pageIndex], offsetInPage < page.validFrames {
                let copyCount = min(page.validFrames - offsetInPage, spanToPageEnd)
                let source = page.channels[channel].advanced(by: offsetInPage)
                let target = destination.advanced(by: destinationOffset + written)
                if gain == 1 {
                    target.update(from: source, count: copyCount)
                } else {
                    for index in 0..<copyCount {
                        target[index] = source[index] * gain
                    }
                }
            }

            written += spanToPageEnd
        }
        os_unfair_lock_unlock(&pageLock)

        return available
    }

    func interpolatedSample(channel: Int, frame: Double) -> Float {
        guard channel >= 0, channel < channelCount, frameCount > 0, frame >= 0 else { return 0 }

        let baseFrame = frame >= Double(frameCount - 1) ? frameCount - 1 : Int(frame.rounded(.down))
        noteRequested(frame: baseFrame)
        let fraction = Float(frame - Double(baseFrame))

        os_unfair_lock_lock(&pageLock)
        defer { os_unfair_lock_unlock(&pageLock) }
        let sampleA = unlockedSample(channel: channel, frame: baseFrame)
        let sampleB = baseFrame + 1 < frameCount
            ? unlockedSample(channel: channel, frame: baseFrame + 1)
            : sampleA
        return sampleA + (sampleB - sampleA) * fraction
    }

    /// Caller must hold `pageLock`.
    private func unlockedSample(channel: Int, frame: Int) -> Float {
        let pageIndex = frame / pageFrames
        let offsetInPage = frame % pageFrames
        guard let page = pages[pageIndex], offsetInPage < page.validFrames else { return 0 }
        return page.channels[channel][offsetInPage]
    }

    private func noteRequested(frame: Int) {
        // Never block the audio thread waiting on the reader.
        guard os_unfair_lock_trylock(&centerLock) else { return }
        requestedCenterFrame = frame
        os_unfair_lock_unlock(&centerLock)
    }

    private func startReaderTimer() {
        let source = DispatchSource.makeTimerSource(queue: readerQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            os_unfair_lock_lock(&self.centerLock)
            let center = self.requestedCenterFrame
            os_unfair_lock_unlock(&self.centerLock)
            self.fillWindow(around: center)
        }
        timer = source
        source.resume()
    }

    /// Runs on `readerQueue`. Evicts out-of-window pages and decodes missing ones.
    private func fillWindow(around centerFrame: Int) {
        let centerPage = centerFrame / pageFrames
        let lowest = max(0, centerPage - lookBehindPages)
        let highest = centerPage + lookAheadPages

        os_unfair_lock_lock(&pageLock)
        let residentIndices = Array(pages.keys)
        os_unfair_lock_unlock(&pageLock)

        for index in residentIndices where index < lowest || index > highest {
            os_unfair_lock_lock(&pageLock)
            pages[index] = nil
            os_unfair_lock_unlock(&pageLock)
        }

        var index = lowest
        while index <= highest {
            guard index * pageFrames < frameCount else { break }

            os_unfair_lock_lock(&pageLock)
            let alreadyResident = pages[index] != nil
            os_unfair_lock_unlock(&pageLock)

            if !alreadyResident, let page = decodePage(index) {
                os_unfair_lock_lock(&pageLock)
                pages[index] = page
                os_unfair_lock_unlock(&pageLock)
            }
            index += 1
        }
    }

    /// Runs on `readerQueue`. Reads one page worth of frames from disk.
    private func decodePage(_ index: Int) -> Page? {
        let startFrame = index * pageFrames
        guard startFrame < frameCount else { return nil }
        let framesToRead = min(pageFrames, frameCount - startFrame)

        do {
            reader.framePosition = AVAudioFramePosition(startFrame)
            readBuffer.frameLength = 0
            try reader.read(into: readBuffer, frameCount: AVAudioFrameCount(framesToRead))
        } catch {
            return nil
        }

        let framesRead = Int(readBuffer.frameLength)
        guard framesRead > 0, let channelData = readBuffer.floatChannelData else { return nil }

        let page = Page(channelCount: channelCount, capacity: pageFrames, validFrames: framesRead)
        for channel in 0..<channelCount {
            page.channels[channel].update(from: channelData[channel], count: framesRead)
        }
        return page
    }
}
