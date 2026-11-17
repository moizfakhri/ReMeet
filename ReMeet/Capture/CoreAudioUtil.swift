import CoreAudio
import Foundation
import ReMeetKit

struct CoreAudioError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            ? " '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : ""
        return "\(operation) failed: OSStatus \(status)\(fourCC)"
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw CoreAudioError(operation: operation, status: status) }
}

enum CoreAudioUtil {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        deviceID(for: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        deviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func deviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = address(selector)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func deviceInfo(_ id: AudioDeviceID) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id,
                        uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                        name: string(id, kAudioObjectPropertyName) ?? "Unknown device",
                        nominalSampleRate: double(id, kAudioDevicePropertyNominalSampleRate) ?? 0)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func double(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func streamFormat(_ id: AudioObjectID,
                             selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var addr = address(selector, scope: scope)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }

    /// The Core Audio process object for a pid, used to exclude ReMeet itself from the tap.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Watches the system default input and output devices (e.g. AirPods connecting or
/// disconnecting). Callbacks arrive on the main queue.
final class DefaultDeviceMonitor {
    enum Kind { case input, output }

    var onChange: ((Kind) -> Void)?
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        register(kAudioHardwarePropertyDefaultInputDevice, kind: .input)
        register(kAudioHardwarePropertyDefaultOutputDevice, kind: .output)
    }

    deinit {
        for (addr, block) in registrations {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &addr, .main, block)
        }
    }

    private func register(_ selector: AudioObjectPropertySelector, kind: Kind) {
        var addr = CoreAudioUtil.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?(kind)
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &addr, .main, block) == noErr {
            registrations.append((addr, block))
        }
    }
}
