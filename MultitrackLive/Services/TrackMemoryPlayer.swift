import AVFoundation
import Foundation

/// Pull-based memory playback for one track via `AVAudioSourceNode`.
final class TrackMemoryPlayer {
    struct MixState: Sendable {
        var volume: Float = 1
        var pan: Float = 0
        var isAudible: Bool = true
    }

    private final class RenderContext: @unchecked Sendable {
        let transport: AudioPlaybackTransport
        let buffer: DecodedStemBuffer
        let sampleRate: Double
        var mapper: ArrangementTimelineMapper
        var mix = MixState()

        init(
            transport: AudioPlaybackTransport,
            buffer: DecodedStemBuffer,
            mapper: ArrangementTimelineMapper
        ) {
            self.transport = transport
            self.buffer = buffer
            self.mapper = mapper
            self.sampleRate = buffer.sampleRate
        }

        func render(
            frameCount: AVAudioFrameCount,
            hostTime: UInt64,
            outputBuffer: UnsafeMutablePointer<AudioBufferList>
        ) {
            guard frameCount > 0, sampleRate > 0 else { return }

            clearOutput(outputBuffer, frameCount: frameCount)

            guard mix.isAudible else { return }

            let transportState = transport.renderTimeline(atHostTime: hostTime, captureAnchor: true)
            guard transportState.isPlaying else { return }

            let masterStart = transportState.timelineSeconds
            let ratio = transportState.playbackRatio

            if abs(ratio - 1.0) < 0.0001 {
                renderConstantTempo(
                    masterStart: masterStart,
                    frameCount: frameCount,
                    outputBuffer: outputBuffer
                )
            } else {
                renderResampledTempo(
                    masterStart: masterStart,
                    ratio: ratio,
                    frameCount: frameCount,
                    outputBuffer: outputBuffer
                )
            }
        }

        private func renderConstantTempo(
            masterStart: TimeInterval,
            frameCount: AVAudioFrameCount,
            outputBuffer: UnsafeMutablePointer<AudioBufferList>
        ) {
            let (leftGain, rightGain) = Self.channelGains(for: mix)

            var renderedFrames: AVAudioFrameCount = 0
            var masterTime = masterStart

            while renderedFrames < frameCount {
                let bufferRemaining = Double(frameCount - renderedFrames) / sampleRate
                let regionSeconds = mapper.regionRemainingSeconds(
                    fromMasterTimeline: masterTime,
                    bufferLimit: bufferRemaining
                )

                guard regionSeconds > 0,
                      let sourceStart = mapper.sourceSeconds(atMasterTimeline: masterTime) else {
                    break
                }

                let runFrames = min(
                    AVAudioFrameCount(regionSeconds * sampleRate),
                    frameCount - renderedFrames
                )
                guard runFrames > 0 else { break }

                let sourceFrame = Int((sourceStart * sampleRate).rounded(.toNearestOrAwayFromZero))
                mixFromMemory(
                    startingFrame: sourceFrame,
                    frameCount: Int(runFrames),
                    into: outputBuffer,
                    outputFrameOffset: Int(renderedFrames),
                    leftGain: leftGain,
                    rightGain: rightGain
                )

                renderedFrames += runFrames
                masterTime += Double(runFrames) / sampleRate
            }
        }

        private func renderResampledTempo(
            masterStart: TimeInterval,
            ratio: Double,
            frameCount: AVAudioFrameCount,
            outputBuffer: UnsafeMutablePointer<AudioBufferList>
        ) {
            let outputFrames = Int(frameCount)
            guard outputFrames > 0 else { return }

            let (leftGain, rightGain) = Self.channelGains(for: mix)
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBuffer)
            let outputChannelCount = outputBuffers.count
            guard outputChannelCount > 0 else { return }

            if let bounds = mapper.linearResampleBounds(atMasterTimeline: masterStart, sampleRate: sampleRate) {
                renderResampledTempoLinear(
                    startSourceFrame: bounds.startSourceFrame,
                    endSourceFrame: bounds.endSourceFrame,
                    sourceFrameStep: ratio,
                    outputFrames: outputFrames,
                    outputBuffers: outputBuffers,
                    outputChannelCount: outputChannelCount,
                    leftGain: leftGain,
                    rightGain: rightGain
                )
                return
            }

            renderResampledTempoMapped(
                masterStart: masterStart,
                ratio: ratio,
                outputFrames: outputFrames,
                outputBuffers: outputBuffers,
                outputChannelCount: outputChannelCount,
                leftGain: leftGain,
                rightGain: rightGain
            )
        }

        private func renderResampledTempoLinear(
            startSourceFrame: Double,
            endSourceFrame: Double,
            sourceFrameStep: Double,
            outputFrames: Int,
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            outputChannelCount: Int,
            leftGain: Float,
            rightGain: Float
        ) {
            var sourceFrame = startSourceFrame

            for outputFrame in 0..<outputFrames {
                guard sourceFrame < endSourceFrame else { break }
                writeResampledFrame(
                    sourceFrame: sourceFrame,
                    outputFrame: outputFrame,
                    outputBuffers: outputBuffers,
                    outputChannelCount: outputChannelCount,
                    leftGain: leftGain,
                    rightGain: rightGain
                )
                sourceFrame += sourceFrameStep
            }
        }

        private func renderResampledTempoMapped(
            masterStart: TimeInterval,
            ratio: Double,
            outputFrames: Int,
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            outputChannelCount: Int,
            leftGain: Float,
            rightGain: Float
        ) {
            var renderedFrames = 0
            var masterTime = masterStart
            let masterStep = ratio / sampleRate

            while renderedFrames < outputFrames {
                let bufferRemaining = Double(outputFrames - renderedFrames) / sampleRate
                let regionSeconds = mapper.regionRemainingSeconds(
                    fromMasterTimeline: masterTime,
                    bufferLimit: bufferRemaining
                )

                guard regionSeconds > 0,
                      let sourceStart = mapper.sourceSeconds(atMasterTimeline: masterTime) else {
                    break
                }

                let runFrames = min(
                    Int((regionSeconds * sampleRate).rounded(.down)),
                    outputFrames - renderedFrames
                )
                guard runFrames > 0 else { break }

                var sourceFrame = sourceStart * sampleRate

                for offset in 0..<runFrames {
                    writeResampledFrame(
                        sourceFrame: sourceFrame,
                        outputFrame: renderedFrames + offset,
                        outputBuffers: outputBuffers,
                        outputChannelCount: outputChannelCount,
                        leftGain: leftGain,
                        rightGain: rightGain
                    )
                    sourceFrame += ratio
                    masterTime += masterStep
                }

                renderedFrames += runFrames
            }
        }

        private func writeResampledFrame(
            sourceFrame: Double,
            outputFrame: Int,
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            outputChannelCount: Int,
            leftGain: Float,
            rightGain: Float
        ) {
            if buffer.channelCount == 1 {
                guard let outputData = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                outputData[outputFrame] = buffer.interpolatedSample(channel: 0, frame: sourceFrame) * leftGain
                return
            }

            if outputChannelCount >= 2, buffer.channelCount >= 2 {
                if let leftOutput = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    leftOutput[outputFrame] = buffer.interpolatedSample(channel: 0, frame: sourceFrame) * leftGain
                }
                if let rightOutput = outputBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    rightOutput[outputFrame] = buffer.interpolatedSample(channel: 1, frame: sourceFrame) * rightGain
                }
                return
            }

            for channel in 0..<min(buffer.channelCount, outputChannelCount) {
                guard let outputData = outputBuffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                outputData[outputFrame] = buffer.interpolatedSample(channel: channel, frame: sourceFrame) * mix.volume
            }
        }

        private func mixFromMemory(
            startingFrame: Int,
            frameCount: Int,
            into outputBufferList: UnsafeMutablePointer<AudioBufferList>,
            outputFrameOffset: Int,
            leftGain: Float,
            rightGain: Float
        ) {
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
            let outputChannelCount = outputBuffers.count
            guard outputChannelCount > 0, frameCount > 0 else { return }

            if buffer.channelCount == 1 {
                let gain = leftGain
                guard let outputData = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                _ = buffer.copy(
                    channel: 0,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    into: outputData,
                    destinationOffset: outputFrameOffset,
                    gain: gain
                )
                return
            }

            if outputChannelCount >= 2, buffer.channelCount >= 2 {
                if let leftOutput = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    _ = buffer.copy(
                        channel: 0,
                        startingFrame: startingFrame,
                        frameCount: frameCount,
                        into: leftOutput,
                        destinationOffset: outputFrameOffset,
                        gain: leftGain
                    )
                }

                if let rightOutput = outputBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    _ = buffer.copy(
                        channel: 1,
                        startingFrame: startingFrame,
                        frameCount: frameCount,
                        into: rightOutput,
                        destinationOffset: outputFrameOffset,
                        gain: rightGain
                    )
                }
                return
            }

            for channel in 0..<min(buffer.channelCount, outputChannelCount) {
                guard let outputData = outputBuffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                _ = buffer.copy(
                    channel: channel,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    into: outputData,
                    destinationOffset: outputFrameOffset,
                    gain: mix.volume
                )
            }
        }

        private func clearOutput(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) {
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            _ = frameCount
        }

        private static func channelGains(for mix: MixState) -> (left: Float, right: Float) {
            guard mix.isAudible, mix.volume > 0 else { return (0, 0) }

            let pan = max(-1, min(1, mix.pan))
            let theta = (pan + 1) * Float.pi / 4
            return (mix.volume * cos(theta), mix.volume * sin(theta))
        }
    }

    let trackID: UUID
    let sourceNode: AVAudioSourceNode
    let decodedBuffer: DecodedStemBuffer
    private let renderContext: RenderContext

    init(
        trackID: UUID,
        buffer: DecodedStemBuffer,
        transport: AudioPlaybackTransport,
        mapper: ArrangementTimelineMapper
    ) {
        self.trackID = trackID
        self.decodedBuffer = buffer
        self.renderContext = RenderContext(
            transport: transport,
            buffer: buffer,
            mapper: mapper
        )

        let format = buffer.audioFormat
        let context = renderContext

        sourceNode = AVAudioSourceNode(format: format) { _, timestamp, frameCount, outputData in
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()

            context.render(
                frameCount: frameCount,
                hostTime: hostTime,
                outputBuffer: outputData
            )
            return noErr
        }
    }

    func updateMapper(_ mapper: ArrangementTimelineMapper) {
        renderContext.mapper = mapper
    }

    func updateMix(volume: Float, pan: Float, isAudible: Bool) {
        renderContext.mix = MixState(volume: volume, pan: pan, isAudible: isAudible)
    }
}
