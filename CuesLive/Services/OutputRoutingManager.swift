import AVFoundation
import Foundation

enum OutputRoutingManager {
    /// Routes stereo source nodes to hardware outs via AU channel maps.
    ///
    /// Maps are applied on each `AVAudioSourceNode` after connecting with a
    /// multi-channel format at the stem/engine sample rate. Returns `false` when
    /// the device is stereo-only so the caller can use the master-mixer path.
    @discardableResult
    static func applyChannelMapRouting(
        engine: AVAudioEngine,
        tracks: [(sourceNode: AVAudioNode, destination: OutputDestination)],
        outputChannelCount: Int
    ) -> Bool {
        let channelCount = max(outputChannelCount, 2)
        guard channelCount > 2 else { return false }

        guard let multiChannelFormat = AudioOutputDeviceService.multiChannelFormat(
            sampleRate: DecodedStemBuffer.engineSampleRate,
            channelCount: channelCount
        ) else {
            return false
        }

        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: multiChannelFormat)

        var connectedTracks = 0
        for track in tracks {
            let map = channelMap(for: track.destination, outputChannelCount: channelCount)
            guard map.contains(where: { $0.intValue >= 0 }) else { continue }

            engine.disconnectNodeOutput(track.sourceNode)
            track.sourceNode.auAudioUnit.channelMap = nil
            engine.connect(track.sourceNode, to: engine.mainMixerNode, format: multiChannelFormat)
            track.sourceNode.auAudioUnit.channelMap = map
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
            guard left >= 0, right < outputChannelCount else {
                return defaultStereoMap(outputChannelCount)
            }
            map[left] = 0
            map[right] = 1
        case .mono(let channel):
            let index = channel - 1
            guard index >= 0, index < outputChannelCount else {
                return defaultStereoMap(outputChannelCount)
            }
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
