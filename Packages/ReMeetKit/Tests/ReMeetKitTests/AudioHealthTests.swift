import Foundation
import Testing
@testable import ReMeetKit

@Suite("AudioHealthEvaluator")
struct AudioHealthTests {
    @Test("Healthy recording with active mic and call audio reports nil")
    func healthyRecording() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 45,
            micDeviceName: "AirPods Pro",
            isBluetoothInput: true,
            heardMicSpeech: true,
            heardMicSignal: true,
            heardCallAudio: true,
            otherAppPlayingAudio: true
        )
        #expect(AudioHealthEvaluator.evaluate(t) == nil)
    }

    @Test("Detects OS/hardware muted microphone within 5 seconds")
    func detectsMutedMic() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 6,
            micDeviceName: "AirPods Pro",
            isBluetoothInput: true,
            isInputMutedInOS: true
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .micMutedInOS)
        #expect(issue?.action == .openMicSettings)
    }

    @Test("Detects stalled Bluetooth or CoreAudio stream when chunks stop arriving")
    func detectsStalledStream() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 10,
            micDeviceName: "AirPods Pro",
            isBluetoothInput: true,
            secondsSinceLastMicChunk: 6.4,
            heardMicSpeech: true,
            heardMicSignal: true,
            heardCallAudio: true
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .streamStalled)
        #expect(issue?.action == .restartCapture)
        #expect(issue?.detail.contains("Bluetooth") == true)
    }

    @Test("Detects Meeting Apps Only scope mismatch when another app plays audio")
    func detectsMeetingScopeMismatch() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 9,
            micDeviceName: "MacBook Pro Microphone",
            heardMicSpeech: true,
            heardMicSignal: true,
            heardCallAudio: false,
            otherAppPlayingAudio: true,
            scopeIsMeetingAppsOnly: true,
            matchedMeetingProcessCount: 0
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .meetingScopeNoMatch)
        #expect(issue?.action == .switchToAllAppsScope)
    }

    @Test("Detects blocked call audio when another app outputs sound and tap stays silent")
    func detectsCallAudioBlocked() {
        var t = AudioHealthTelemetry(
            elapsedSeconds: 9,
            micDeviceName: "MacBook Pro Microphone",
            heardMicSpeech: true,
            heardMicSignal: true,
            heardCallAudio: false,
            otherAppPlayingAudio: true
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .callAudioBlocked)
        #expect(issue?.action == .openSystemAudioSettings)

        // Clears automatically as soon as call audio arrives.
        t.heardCallAudio = true
        #expect(AudioHealthEvaluator.evaluate(t) == nil)
    }

    @Test("Detects call-app microphone mismatch (e.g. AirPods in Zoom vs MacBook Mic)")
    func detectsCallAppMicMismatch() {
        var t = AudioHealthTelemetry(
            elapsedSeconds: 7,
            micDeviceName: "MacBook Pro Microphone",
            heardMicSpeech: false,
            heardMicSignal: true,
            heardCallAudio: true,
            otherAppPlayingAudio: true,
            mismatchedCallAppMic: (appName: "Zoom", micName: "AirPods Pro")
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .micDeviceMismatch)
        #expect(issue?.action == .followMeetingMic)
        #expect(issue?.title.contains("AirPods Pro") == true)

        // Clears if speech arrives or once ReMeet switches to AirPods Pro.
        t.mismatchedCallAppMic = nil
        #expect(AudioHealthEvaluator.evaluate(t) == nil)
    }

    @Test("Detects digital-zero flatline on microphone (clamshell closed / dead mic)")
    func detectsMicFlatlineZeroes() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 14,
            micDeviceName: "MacBook Pro Microphone",
            heardMicSpeech: false,
            heardMicSignal: false,
            heardCallAudio: true
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .micFlatlineZeroes)
        #expect(issue?.action == .restartCapture)
    }

    @Test("Warns after 25s when neither voice nor call audio has been heard, and respects dismissal")
    func detectsBothTracksSilentAndHonorsDismissal() {
        let t = AudioHealthTelemetry(
            elapsedSeconds: 26,
            micDeviceName: "AirPods Pro",
            heardMicSpeech: false,
            heardMicSignal: true,
            heardCallAudio: false,
            otherAppPlayingAudio: false
        )
        let issue = AudioHealthEvaluator.evaluate(t)
        #expect(issue?.kind == .bothTracksSilent)

        let dismissed = AudioHealthEvaluator.evaluate(t, dismissed: [.bothTracksSilent])
        #expect(dismissed == nil)
    }
}
