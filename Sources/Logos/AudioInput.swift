import AVFoundation
import CoreAudio

/// The microphones Logos can record from. By default it records from the Mac's
/// built-in microphone, whatever macOS's default input is, so plugging in an
/// audio interface or a monitor doesn't silently switch Logos to a device with
/// no mic attached.
enum AudioInput {
    struct Device: Equatable {
        var id: AudioDeviceID
        var uid: String
        var name: String
        var isBuiltIn: Bool
    }

    /// `inputDevice` values with a meaning of their own; anything else is a device's UID.
    static let builtIn = "builtIn"
    static let systemDefault = "system"

    /// Every connected device with at least one input channel.
    static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                          isBuiltIn: transportType(id) == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// The device to record from for an `inputDevice` setting, or nil to use
    /// macOS's default input. A device that isn't connected falls back to the
    /// built-in microphone.
    static func resolve(_ setting: String, among devices: [Device]) -> Device? {
        let fallback = devices.first(where: \.isBuiltIn)
        switch setting {
        case Self.systemDefault: return nil
        case Self.builtIn: return fallback
        default: return devices.first { $0.uid == setting } ?? fallback
        }
    }

    /// Points an engine's input at `device`, before the engine reads its format.
    static func select(_ device: Device, for engine: AVAudioEngine) throws {
        guard let unit = engine.inputNode.audioUnit else { throw LogosError("The microphone isn't available") }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw LogosError("Couldn't record from \(device.name) (error \(status))") }
    }

    // MARK: Core Audio properties

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
}
