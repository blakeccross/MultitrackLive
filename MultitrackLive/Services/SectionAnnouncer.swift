import AVFoundation
import Foundation

/// Pre-renders section names with TTS and plays them through the shared audio engine.
@Observable
final class SectionAnnouncer {
    private let synthesizer = AVSpeechSynthesizer()
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var renderTasks: [String: Task<Void, Never>] = [:]

    func prepare(names: [String]) {
        let unique = Set(
            names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        let staleKeys = cache.keys.filter { !unique.contains($0) }
        for key in staleKeys {
            cache.removeValue(forKey: key)
            renderTasks.removeValue(forKey: key)?.cancel()
        }

        for name in unique where cache[name] == nil && renderTasks[name] == nil {
            renderTasks[name] = Task { [weak self] in
                guard let self else { return }
                if let buffer = await self.renderSpeechBuffer(for: name) {
                    guard !Task.isCancelled else { return }
                    self.cache[name] = buffer
                }
                self.renderTasks[name] = nil
            }
        }
    }

    func announce(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let buffer = cache[trimmed] {
            AudioEngineManager.shared.playAnnouncement(buffer)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            if let buffer = await self.renderSpeechBuffer(for: trimmed) {
                self.cache[trimmed] = buffer
                await MainActor.run {
                    AudioEngineManager.shared.playAnnouncement(buffer)
                }
            }
        }
    }

    func clearCache() {
        for task in renderTasks.values {
            task.cancel()
        }
        renderTasks.removeAll()
        cache.removeAll()
    }

    private func renderSpeechBuffer(for name: String) async -> AVAudioPCMBuffer? {
        let utterance = AVSpeechUtterance(string: name)
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

        guard let concatenated = Self.concatenate(chunks) else { return nil }
        return Self.convertIfNeeded(concatenated, to: Self.engineFormat)
    }

    private static var engineFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: DecodedStemBuffer.engineSampleRate,
            channels: 2
        ) ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
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

    private static func convertIfNeeded(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == format.sampleRate,
           buffer.format.channelCount == format.channelCount,
           buffer.format.commonFormat == format.commonFormat {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return buffer
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return buffer
        }

        var error: NSError?
        var consumedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        if error != nil {
            return buffer
        }
        return converted
    }
}
