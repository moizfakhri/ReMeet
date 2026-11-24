import CoreAudio
import Foundation

/// Which processes are using audio input, from Core Audio's process objects (macOS 14+).
/// Event-driven: listeners on the process list and on each process's "running input"
/// flag; nothing polls. Core Audio IPC runs on a private utility queue; callbacks arrive on main.
final class AudioProcessMonitor {
    struct Process: Equatable {
        var object: AudioObjectID
        var pid: pid_t
        var bundleID: String
        var isRunningInput: Bool
        var isRunningOutput: Bool
    }

    /// Bundle IDs of processes currently capturing audio (ReMeet itself excluded).
    var onInputChange: ((Set<String>) -> Void)?
    /// An audio process appeared or went away (apps launched or quit).
    var onProcessListChange: (() -> Void)?
    /// Fired when any input device starts or stops running (e.g. Zoom switches onto AirPods mid-call).
    var onInputDeviceActivity: (() -> Void)?

    private let queue = DispatchQueue(label: "com.moizfakhri.ReMeet.audioProcessMonitor", qos: .utility)
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// The per-process "running input" notification is not delivered reliably on macOS 27
    /// (measured by `--selftest processmonitor`), so every input-capable device's
    /// "running somewhere" flag (including AirPods when selected inside Zoom while MacBook Mic
    /// remains system default) is watched as well. Still event-driven: no polling.
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var hardwareDevicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var lastReported: Set<String> = []
    private var started = false

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    private func startOnQueue() {
        guard !started, listListener == nil else { return }
        started = true
        var address = CoreAudioUtil.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processListChanged() }
        if AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &address, queue, block) == noErr {
            listListener = block
        }
        var defaultAddress = CoreAudioUtil.address(kAudioHardwarePropertyDefaultInputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.watchInputDevices() }
        if AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &defaultAddress, queue, defaultBlock) == noErr {
            defaultInputListener = defaultBlock
        }
        var devicesAddress = CoreAudioUtil.address(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.watchInputDevices() }
        if AudioObjectAddPropertyListenerBlock(CoreAudioUtil.systemObject, &devicesAddress, queue, devicesBlock) == noErr {
            hardwareDevicesListener = devicesBlock
        }
        watchInputDevices()
        processListChanged()
    }

    private func watchInputDevices() {
        var desired = Set(CoreAudioUtil.allInputDevices())
        if let def = CoreAudioUtil.defaultInputDevice() { desired.insert(def) }

        for device in desired where deviceListeners[device] == nil {
            var address = CoreAudioUtil.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.report()
                self?.notifyDeviceActivity()
                // The device flips before the process flags settle; read again shortly after.
                self?.queue.asyncAfter(deadline: .now() + 0.35) {
                    self?.report()
                    self?.notifyDeviceActivity()
                }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                deviceListeners[device] = block
            }
        }
        for device in Array(deviceListeners.keys) where !desired.contains(device) {
            if let block = deviceListeners.removeValue(forKey: device) {
                var address = CoreAudioUtil.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
        report()
    }

    private func notifyDeviceActivity() {
        guard let callback = onInputDeviceActivity else { return }
        DispatchQueue.main.async { callback() }
    }

    func stop() {
        let tearDown = {
            self.started = false
            for (device, block) in self.deviceListeners {
                var address = CoreAudioUtil.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                AudioObjectRemovePropertyListenerBlock(device, &address, self.queue, block)
            }
            self.deviceListeners = [:]
            if let hardwareDevicesListener = self.hardwareDevicesListener {
                var address = CoreAudioUtil.address(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &address, self.queue, hardwareDevicesListener)
            }
            self.hardwareDevicesListener = nil
            if let defaultInputListener = self.defaultInputListener {
                var address = CoreAudioUtil.address(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &address, self.queue, defaultInputListener)
            }
            self.defaultInputListener = nil
            if let listListener = self.listListener {
                var address = CoreAudioUtil.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(CoreAudioUtil.systemObject, &address, self.queue, listListener)
            }
            self.listListener = nil
            for (object, block) in self.processListeners {
                var address = CoreAudioUtil.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, self.queue, block)
            }
            self.processListeners = [:]
            self.lastReported = []
        }
        queue.sync(execute: tearDown)
    }

    /// All audio process objects right now (also used by the "meeting apps only" tap).
    static func processes() -> [Process] {
        var address = CoreAudioUtil.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CoreAudioUtil.systemObject, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CoreAudioUtil.systemObject, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = getpid()
        return objects.compactMap { object in
            let pid = Int32(CoreAudioUtil.uint32(object, kAudioProcessPropertyPID) ?? 0)
            guard pid != me else { return nil }
            return Process(object: object, pid: pid,
                           bundleID: CoreAudioUtil.string(object, kAudioProcessPropertyBundleID) ?? "",
                           isRunningInput: CoreAudioUtil.uint32(object, kAudioProcessPropertyIsRunningInput) == 1,
                           isRunningOutput: CoreAudioUtil.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1)
        }
    }

    private func processListChanged() {
        let current = Self.processes()
        let objects = Set(current.map(\.object))
        // Watch new processes, forget gone ones.
        for process in current where processListeners[process.object] == nil {
            var address = CoreAudioUtil.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
            if AudioObjectAddPropertyListenerBlock(process.object, &address, queue, block) == noErr {
                processListeners[process.object] = block
            }
        }
        for object in Array(processListeners.keys) where !objects.contains(object) {
            if let block = processListeners.removeValue(forKey: object) {
                var address = CoreAudioUtil.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
        }
        report(current)
        if let callback = onProcessListChange {
            DispatchQueue.main.async { callback() }
        }
    }

    private func report(_ current: [Process]? = nil) {
        let inputs = Set((current ?? Self.processes()).filter(\.isRunningInput).map(\.bundleID).filter { !$0.isEmpty })
        guard inputs != lastReported else { return }
        lastReported = inputs
        if let callback = onInputChange {
            DispatchQueue.main.async { callback(inputs) }
        }
    }
}

extension CoreAudioUtil {
    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }
}
