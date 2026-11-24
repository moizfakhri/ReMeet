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
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
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

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        uint32(id, kAudioDevicePropertyTransportType) ?? 0
    }

    /// True for AirPods, Beats, and Bluetooth / BLE headsets whose sample rate renegotiates on HFP call entry.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transportType(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Checks whether macOS or hardware mute is active on the input stream of `id`.
    static func isInputMuted(_ id: AudioDeviceID) -> Bool {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var addr = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, element: element)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted) == noErr, muted != 0 {
                return true
            }
        }
        return false
    }

    /// Total input channel count of `id` (0 for output-only speakers or tap-only aggregates).
    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// All physical/virtual input-capable audio devices currently attached to the Mac (excludes ReMeet's own tap aggregates).
    static func allInputDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { id in
            guard id != kAudioObjectUnknown, inputChannelCount(id) > 0 else { return false }
            let uid = string(id, kAudioDevicePropertyDeviceUID) ?? ""
            return !uid.hasPrefix("com.moizfakhri.ReMeet.")
        }
    }

    static func isDeviceRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// Input devices currently bound to a Core Audio process object (`Zoom`, `Teams`, `Chrome`, etc.).
    static func processInputDevices(_ processObject: AudioObjectID) -> [AudioDeviceID] {
        var addr = address(kAudioProcessPropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(processObject, &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { id in
            guard id != kAudioObjectUnknown, inputChannelCount(id) > 0 else { return false }
            let uid = string(id, kAudioDevicePropertyDeviceUID) ?? ""
            return !uid.hasPrefix("com.moizfakhri.ReMeet.")
        }
    }

    /// Finds the active input device of a running meeting app (`isRunningInput == true`), if any.
    /// Because that meeting app ALREADY has the device open in input mode, following it never
    /// forces an idle Bluetooth headset into call mode.
    static func activeMeetingAppInputDevice() -> (app: MeetingApp, device: AudioDeviceInfo)? {
        for proc in AudioProcessMonitor.processes() where proc.isRunningInput && !proc.bundleID.isEmpty {
            guard let app = MeetingApp.match(proc.bundleID) else { continue }
            for devID in processInputDevices(proc.object) where isDeviceRunningSomewhere(devID) {
                return (app, deviceInfo(devID))
            }
        }
        return nil
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

/// Watches default input/output device switches AND sample-rate / alive changes on the active
/// devices themselves (crucial when AirPods are already the output device at 48 kHz A2DP and
/// renegotiate into 24 kHz / 16 kHz Bluetooth HFP call mode without changing device ID).
final class DefaultDeviceMonitor {
    enum Kind { case input, output }

    var onChange: ((Kind) -> Void)?
    private var systemRegistrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var inputDeviceRegistrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var outputDeviceRegistrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        registerSystem(kAudioHardwarePropertyDefaultInputDevice, kind: .input)
        registerSystem(kAudioHardwarePropertyDefaultOutputDevice, kind: .output)
        rebindActiveDeviceListeners(kind: .input)
        rebindActiveDeviceListeners(kind: .output)
    }

    deinit {
        for (addr, block) in systemRegistrations {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &a, .main, block)
        }
        clearDeviceListeners(&inputDeviceRegistrations)
        clearDeviceListeners(&outputDeviceRegistrations)
    }

    private func registerSystem(_ selector: AudioObjectPropertySelector, kind: Kind) {
        var addr = CoreAudioUtil.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindActiveDeviceListeners(kind: kind)
            self?.onChange?(kind)
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &addr, .main, block) == noErr {
            systemRegistrations.append((addr, block))
        }
    }

    private func rebindActiveDeviceListeners(kind: Kind) {
        switch kind {
        case .input:
            clearDeviceListeners(&inputDeviceRegistrations)
            if let id = CoreAudioUtil.defaultInputDevice() {
                watchDevice(id, into: &inputDeviceRegistrations, kind: .input)
            }
        case .output:
            clearDeviceListeners(&outputDeviceRegistrations)
            if let id = CoreAudioUtil.defaultOutputDevice() {
                watchDevice(id, into: &outputDeviceRegistrations, kind: .output)
            }
        }
    }

    private func watchDevice(_ id: AudioDeviceID,
                             into list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)],
                             kind: Kind) {
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var addr = CoreAudioUtil.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onChange?(kind)
            }
            if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                list.append((id, addr, block))
            }
        }
    }

    private func clearDeviceListeners(_ list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
        for (id, addr, block) in list {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        list.removeAll()
    }
}
