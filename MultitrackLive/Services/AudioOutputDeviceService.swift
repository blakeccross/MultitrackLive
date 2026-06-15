import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

struct AudioOutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let channelCount: Int
}

enum AudioOutputDeviceService {
    static func availableDevices() -> [AudioOutputDevice] {
        #if os(macOS)
        return macOSDevices()
        #else
        return iOSDevices()
        #endif
    }

    static func setSystemDefaultOutputDevice(uid: String) -> Bool {
        #if os(macOS)
        return setMacOSDefaultOutputDevice(uid: uid)
        #else
        return false
        #endif
    }

    static func channelCount(for deviceUID: String?) -> Int {
        if let deviceUID, let device = availableDevices().first(where: { $0.id == deviceUID }) {
            return device.channelCount
        }
        return currentSystemChannelCount()
    }

    static func currentSystemChannelCount() -> Int {
        #if os(macOS)
        return macOSDefaultOutputChannelCount()
        #else
        return iOSOutputChannelCount()
        #endif
    }

    #if os(macOS)
    private static func macOSDevices() -> [AudioOutputDevice] {
        var deviceIDs = [AudioDeviceID]()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputChannels(deviceID: deviceID) else { return nil }
            guard let uid = deviceUID(for: deviceID), let name = deviceName(for: deviceID) else { return nil }
            let channels = outputChannelCount(for: deviceID)
            guard channels > 0 else { return nil }
            return AudioOutputDevice(id: uid, name: name, channelCount: channels)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func setMacOSDefaultOutputDevice(uid: String) -> Bool {
        guard let deviceID = deviceID(forUID: uid) else { return false }
        var mutableID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableID
        ) == noErr
    }

    private static func macOSDefaultOutputChannelCount() -> Int {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return 2 }
        return max(outputChannelCount(for: deviceID), 2)
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceIDs = [AudioDeviceID]()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return nil }

        return deviceIDs.first { deviceUID(for: $0) == uid }
    }

    private static func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        outputChannelCount(for: deviceID) > 0
    }

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }
    #else
    private static func iOSDevices() -> [AudioOutputDevice] {
        let session = AVAudioSession.sharedInstance()
        let routeOutputs = session.currentRoute.outputs
        if routeOutputs.isEmpty {
            return [
                AudioOutputDevice(
                    id: "ios-default",
                    name: "Current Output",
                    channelCount: iOSOutputChannelCount()
                ),
            ]
        }

        return routeOutputs.map { port in
            AudioOutputDevice(
                id: port.uid,
                name: port.portName,
                channelCount: iOSOutputChannelCount()
            )
        }
    }

    private static func iOSOutputChannelCount() -> Int {
        let session = AVAudioSession.sharedInstance()
        return max(session.outputNumberOfChannels, 2)
    }
    #endif
}
