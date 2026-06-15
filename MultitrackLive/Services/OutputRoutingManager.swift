import AVFoundation
import Foundation

final class OutputRoutingManager {
    func teardown(in engine: AVAudioEngine) {
        _ = engine
    }

    /// Routes each track to specific hardware outputs via AU channel maps on the main mixer.
    /// Returns false when the device only supports stereo, so the caller can use the master-mixer path.
    func applyChannelMapRouting(
        engine: AVAudioEngine,
        tracks: [(sourceNode: AVAudioNode, format: AVAudioFormat, destination: OutputDestination)],
        outputChannelCount: Int
    ) -> Bool {
        guard outputChannelCount > 2 else { return false }

        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(outputChannelCount)
        ) else { return false }

        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        var connectedTracks = 0
        for track in tracks {
            let map = Self.channelMap(for: track.destination, outputChannelCount: outputChannelCount)
            guard map.contains(where: { $0.intValue >= 0 }) else { continue }

            track.sourceNode.auAudioUnit.channelMap = map
            engine.connect(track.sourceNode, to: engine.mainMixerNode, format: outputFormat)
            connectedTracks += 1
        }

        return connectedTracks > 0
    }

    static func channelMap(for destination: OutputDestination, outputChannelCount: Int) -> [NSNumber] {
        var map = Array(repeating: NSNumber(value: -1), count: outputChannelCount)
        switch destination {
        case .stereoPair(let start):
            let left = start - 1
            let right = start
            guard left >= 0, right < outputChannelCount else { return defaultStereoMap(outputChannelCount) }
            map[left] = 0
            map[right] = 1
        case .mono(let channel):
            let index = channel - 1
            guard index >= 0, index < outputChannelCount else { return defaultStereoMap(outputChannelCount) }
            map[index] = 0
        }
        return map
    }

    static func defaultStereoMap(_ count: Int) -> [NSNumber] {
        var map = Array(repeating: NSNumber(value: -1), count: count)
        if count >= 1 { map[0] = 0 }
        if count >= 2 { map[1] = 1 }
        return map
    }

    static func clearChannelMap(on node: AVAudioNode) {
        node.auAudioUnit.channelMap = [NSNumber(value: 0), NSNumber(value: 1)]
    }
}
