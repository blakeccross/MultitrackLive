import AVFoundation
import Foundation

/// Procedural click playback for click-only songs with no fixed end time.
final class RealtimeClickTrackPlayer {
    struct Configuration: Sendable {
        var tempoChanges: [TempoChange]
        var timeSignatureChanges: [TimeSignatureChange]
        var subdivision: ClickTrackSubdivision
        var isEnabled: Bool
        var volume: Float
        var pan: Float
    }

    private struct MixState: Sendable {
        var volume: Float = 1
        var pan: Float = 0
        var isAudible: Bool = true
    }

    private final class RenderContext: @unchecked Sendable {
        let transport: AudioPlaybackTransport
        let accentSample: DecodedStemBuffer
        let normalSample: DecodedStemBuffer
        let sampleRate: Double
        var configuration: Configuration
        var mix = MixState()

        init(
            transport: AudioPlaybackTransport,
            accentSample: DecodedStemBuffer,
            normalSample: DecodedStemBuffer,
            configuration: Configuration
        ) {
            self.transport = transport
            self.accentSample = accentSample
            self.normalSample = normalSample
            self.configuration = configuration
            sampleRate = accentSample.sampleRate
        }

        func render(
            frameCount: AVAudioFrameCount,
            hostTime: UInt64,
            outputBuffer: UnsafeMutablePointer<AudioBufferList>
        ) {
            guard frameCount > 0, sampleRate > 0 else { return }

            clearOutput(outputBuffer, frameCount: frameCount)

            guard configuration.isEnabled, mix.isAudible else { return }

            let transportState = transport.renderTimeline(atHostTime: hostTime, captureAnchor: true)
            guard transportState.isPlaying else { return }

            let masterStart = transportState.timelineSeconds
            let windowEnd = masterStart + Double(frameCount) / sampleRate
            let clicks = ClickTrackScheduler.scheduledClicks(
                from: masterStart,
                to: windowEnd,
                tempoChanges: configuration.tempoChanges,
                timeSignatureChanges: configuration.timeSignatureChanges,
                subdivision: configuration.subdivision
            )

            guard !clicks.isEmpty else { return }

            let (leftGain, rightGain) = Self.channelGains(for: mix)
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBuffer)
            let outputChannelCount = outputBuffers.count

            for click in clicks {
                let outputFrameOffset = Int(((click.time - masterStart) * sampleRate).rounded())
                guard outputFrameOffset >= 0, outputFrameOffset < Int(frameCount) else { continue }

                let sample = click.isAccent ? accentSample : normalSample
                let remainingFrames = Int(frameCount) - outputFrameOffset
                let framesToCopy = min(sample.frameCount, remainingFrames)
                guard framesToCopy > 0 else { continue }

                if outputChannelCount == 1 {
                    guard let outputData = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    _ = sample.copy(
                        channel: 0,
                        startingFrame: 0,
                        frameCount: framesToCopy,
                        into: outputData,
                        destinationOffset: outputFrameOffset,
                        gain: mix.volume
                    )
                    continue
                }

                if outputChannelCount >= 2, sample.channelCount >= 2 {
                    if let leftOutput = outputBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                        _ = sample.copy(
                            channel: 0,
                            startingFrame: 0,
                            frameCount: framesToCopy,
                            into: leftOutput,
                            destinationOffset: outputFrameOffset,
                            gain: leftGain
                        )
                    }
                    if let rightOutput = outputBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                        _ = sample.copy(
                            channel: 1,
                            startingFrame: 0,
                            frameCount: framesToCopy,
                            into: rightOutput,
                            destinationOffset: outputFrameOffset,
                            gain: rightGain
                        )
                    }
                    continue
                }

                for channel in 0..<min(sample.channelCount, outputChannelCount) {
                    guard let outputData = outputBuffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    _ = sample.copy(
                        channel: channel,
                        startingFrame: 0,
                        frameCount: framesToCopy,
                        into: outputData,
                        destinationOffset: outputFrameOffset,
                        gain: mix.volume
                    )
                }
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
    let audioFormat: AVAudioFormat
    private let renderContext: RenderContext

    init(
        trackID: UUID,
        transport: AudioPlaybackTransport,
        configuration: Configuration
    ) throws {
        self.trackID = trackID
        let accentSample = try ClickTrackGenerator.sharedAccentSample()
        let normalSample = try ClickTrackGenerator.sharedNormalSample()
        self.renderContext = RenderContext(
            transport: transport,
            accentSample: accentSample,
            normalSample: normalSample,
            configuration: configuration
        )
        audioFormat = accentSample.audioFormat

        let context = renderContext
        sourceNode = AVAudioSourceNode(format: audioFormat) { _, timestamp, frameCount, outputData in
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

    func updateConfiguration(_ configuration: Configuration) {
        renderContext.configuration = configuration
    }

    func updateMix(volume: Float, pan: Float, isAudible: Bool) {
        renderContext.mix = MixState(volume: volume, pan: pan, isAudible: isAudible)
    }
}
