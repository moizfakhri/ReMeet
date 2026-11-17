import AudioToolbox
import CoreAudio
import Foundation
import ReMeetKit

/// Captures everything the Mac plays (the call audio) with a Core Audio process tap.
///
/// Recipe (macOS 14.2+): a global mono CATapDescription that excludes ReMeet itself,
/// AudioHardwareCreateProcessTap, then a private **tap-only** aggregate (no physical
/// output in the subdevice list) whose tap list holds the tap. An IOProc on the
/// aggregate receives the tapped audio. No virtual driver and no screen-recording
/// permission; macOS asks for "System Audio Recording" the first time.
///
/// Pinning the default output as MainSubDevice / SubDeviceList forces coreaudiod to
/// reconcile the aggregate clock with the speakers on every IO cycle, which inserts
/// or drops samples and shows up as crackles in music and calls while ReMeet records.
/// A tap-only aggregate with sub-tap drift compensation keeps that reconciliation
/// inside the capture path. Output-device changes still rebuild the aggregate so a
/// stalled IO proc after an AirPods / HFP flip can recover.
final class SystemAudioCapture {
    struct StartInfo {
        var outputDevice: AudioDeviceInfo?
        var sampleRate: Double
        var channels: UInt32
    }

    private let queue: ChunkQueue
    /// "Meeting apps only": returns the process objects to tap. Nil (the default) taps every app
    /// except ReMeet; when set and empty, waits until a meeting app appears instead of tapping all apps.
    var processFilter: (() -> [AudioObjectID])?
    /// What the current tap covers, for the event log.
    private(set) var scopeDescription = "all apps"
    private let ioQueue = DispatchQueue(label: "com.moizfakhri.ReMeet.tap-io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(queue: ChunkQueue) {
        self.queue = queue
    }

    func start() throws -> StartInfo {
        if let processFilter {
            let included = processFilter()
            if included.isEmpty {
                scopeDescription = "meeting apps only (waiting for a meeting app)"
                let output = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)
                return StartInfo(outputDevice: output, sampleRate: 0, channels: 0)
            }
            if tapID == kAudioObjectUnknown { try createTap(included: included) }
        } else if tapID == kAudioObjectUnknown {
            try createTap(included: nil)
        }
        return try startAggregate()
    }

    /// Tears down and recreates the aggregate (output device flipped, wake from sleep).
    func rebuild() throws -> StartInfo {
        stopAggregate()
        return try start()
    }

    /// Recreates the tap itself (the set of meeting-app processes changed).
    func rebuildTap() throws -> StartInfo {
        stopAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        return try start()
    }

    func stop() {
        stopAggregate()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Private

    private func createTap(included: [AudioObjectID]?) throws {
        let description: CATapDescription
        if let included {
            description = CATapDescription(monoMixdownOfProcesses: included)
            scopeDescription = "meeting apps only (\(included.count) processes)"
        } else {
            var excluded: [AudioObjectID] = []
            if let me = CoreAudioUtil.processObject(for: getpid()) { excluded.append(me) }
            description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
            scopeDescription = "all apps"
        }
        description.name = "ReMeet Call Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), "AudioHardwareCreateProcessTap")
        tapID = id
        tapUID = description.uuid.uuidString
    }

    private func startAggregate() throws -> StartInfo {
        // Report the current default output for diagnostics only — it is not part of the
        // aggregate (see type comment). Missing output is unusual but not fatal for a
        // tap-only device.
        let output = CoreAudioUtil.defaultOutputDevice().map(CoreAudioUtil.deviceInfo)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReMeet Call Tap",
            kAudioAggregateDeviceUIDKey: "com.moizfakhri.ReMeet.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // Tap-only: do not set MainSubDevice / SubDeviceList to the speakers.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        do {
            // What the IOProc actually receives is the aggregate's input stream format;
            // fall back to the tap's own format if the aggregate does not report one.
            guard let format = CoreAudioUtil.streamFormat(aggregate, selector: kAudioDevicePropertyStreamFormat,
                                                          scope: kAudioObjectPropertyScopeInput)
                    ?? CoreAudioUtil.streamFormat(tapID, selector: kAudioTapPropertyFormat,
                                                  scope: kAudioObjectPropertyScopeGlobal) else {
                throw CoreAudioError(operation: "Read tap stream format", status: kAudioHardwareUnspecifiedError)
            }
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw CoreAudioError(operation: "Tap format is not Float32 PCM", status: kAudioHardwareUnsupportedOperationError)
            }

            let raw = queue.raw
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let channels = max(format.mChannelsPerFrame, 1)
            let rate = format.mSampleRate
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { now, inputData, inputTime, _, _ in
                let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid)
                    ? inputTime.pointee.mHostTime : now.pointee.mHostTime
                RMChunkQueuePush(raw, inputData, interleaved, channels, UInt32.max, hostTime, rate)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(aggregate, proc), "AudioDeviceStart")
            return StartInfo(outputDevice: output, sampleRate: rate, channels: channels)
        } catch {
            stopAggregate()
            throw error
        }
    }

    private func stopAggregate() {
        guard aggregateID != kAudioObjectUnknown else { return }
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
}
