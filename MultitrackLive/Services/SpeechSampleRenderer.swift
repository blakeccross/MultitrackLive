import AVFoundation
import Foundation

/// Renders short spoken phrases with system TTS into engine-rate mono stems.
@MainActor
enum SpeechSampleRenderer {
    private static let synthesizer = AVSpeechSynthesizer()

    /// Returns a mono float32 buffer at `DecodedStemBuffer.engineSampleRate`, or nil on failure.
    static func renderMonoStem(for text: String) async -> DecodedStemBuffer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
            ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        let chunks: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            var buffers: [AVAudioPCMBuffer] = []
            var didFinish = false

            synthesizer.write(utterance) { buffer in
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    buffers.append(pcm)
                    return
                }

                guard !didFinish else { return }
                didFinish = true
                continuation.resume(returning: buffers)
            }
        }

        guard let concatenated = concatenate(chunks) else { return nil }
        return try? DecodedStemBuffer.monoStem(from: concatenated)
    }

    private static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        guard buffers.count > 1 else { return first }

        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let output = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            return nil
        }
        output.frameLength = AVAudioFrameCount(totalFrames)

        var writeOffset = 0
        for buffer in buffers {
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { continue }

            if first.format.isInterleaved {
                guard let dst = output.floatChannelData?[0],
                      let src = buffer.floatChannelData?[0] else { return nil }
                let channelCount = Int(first.format.channelCount)
                dst.advanced(by: writeOffset * channelCount)
                    .update(from: src, count: frameCount * channelCount)
            } else {
                let channelCount = Int(first.format.channelCount)
                for channel in 0..<channelCount {
                    guard let dst = output.floatChannelData?[channel],
                          let src = buffer.floatChannelData?[channel] else { return nil }
                    dst.advanced(by: writeOffset).update(from: src, count: frameCount)
                }
            }
            writeOffset += frameCount
        }

        return output
    }
}
