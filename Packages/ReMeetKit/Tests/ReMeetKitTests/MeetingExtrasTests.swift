import Foundation
import Testing
@testable import ReMeetKit

struct MeetingExtrasTests {
    @Test func wordCountSkipsNotesAndCollapsesSpace() {
        let transcript = Transcript(engine: "x", segments: [
            TranscriptSegment(start: 0, end: 1, speaker: "you", text: "Hello  there", source: .mic),
            TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "one two three", source: .system),
            TranscriptSegment(start: 2, end: 3, speaker: "you", text: "  ", source: .mic),
        ])
        #expect(transcript.wordCount == 5)
    }

    @Test func oldDiarizationFileHasNoEmbeddings() throws {
        let json = #"{"engine":"pyannote","mic":[],"system":[{"start":1,"end":2,"speaker":"speaker_1"}]}"#
        let decoded = try JSONCoding.decoder().decode(Diarization.self, from: Data(json.utf8))
        #expect(decoded.embeddings.isEmpty)
        #expect(decoded.system.first?.speaker == "speaker_1")
    }

    @Test func normalizerCarriesEmbeddings() {
        let raw = [SpeechSegment(start: 10, end: 12, speaker: "S7"),
                   SpeechSegment(start: 2, end: 5, speaker: "S3")]
        let out = SpeakerNormalizer.normalize(raw, embeddings: ["S3": [1, 0], "S7": [0, 1], "missing": []])
        #expect(out.segments.map(\.speaker) == ["speaker_1", "speaker_2"])
        #expect(out.embeddings["speaker_1"] == [1, 0])
        #expect(out.embeddings["speaker_2"] == [0, 1])
        #expect(out.embeddings["missing"] == nil)
    }

    @Test func originalAudioPrefersTheWavs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-audio-\(UUID().uuidString)", isDirectory: true)
        let folder = MeetingFolder.makeNew(in: root, start: Date(), title: "Audio")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(folder.originalAudioURLs().isEmpty)
        try Data("m4a".utf8).write(to: folder.file(.audio))
        #expect(folder.originalAudioURLs().map(\.lastPathComponent) == ["audio.m4a"])
        try Data("wav".utf8).write(to: folder.file(.micWAV))
        try Data("wav".utf8).write(to: folder.file(.systemWAV))
        #expect(folder.originalAudioURLs().map(\.lastPathComponent) == ["mic.wav", "system.wav"])
    }

    @Test func voiceprintMatchesOnceAndSkipsACloseCall() {
        var memory = SpeakerMemory(voices: [
            KnownVoice(name: "Priya", embedding: [1, 0, 0], seconds: 30, updated: Date()),
            KnownVoice(name: "Tom", embedding: [0, 1, 0], seconds: 30, updated: Date()),
        ])
        let named = memory.applying(to: SpeakerNames(), embeddings: [
            "speaker_1": [0.9, 0.1, 0],
            "speaker_2": [0.1, 0.9, 0],
            "speaker_3": [0.7, 0.7, 0],
        ])
        #expect(named.names["speaker_1"] == "Priya")
        #expect(named.names["speaker_2"] == "Tom")
        #expect(named.names["speaker_3"] == nil)
        let kept = memory.applying(to: SpeakerNames(names: ["speaker_1": "Ada"]), embeddings: ["speaker_1": [1, 0, 0]])
        #expect(kept.names["speaker_1"] == "Ada")
        memory.remember(name: "Speaker 1", embedding: [0, 0, 1], seconds: 10)
        #expect(memory.voices.count == 2)
        memory.remember(name: "priya", embedding: [0, 0, 1], seconds: 10)
        #expect(memory.voices.count == 2)
        #expect(memory.voices.first { $0.name.lowercased() == "priya" }?.embedding[2] ?? 0 > 0)
    }

    @Test func screenShareIgnoresAnOrdinaryZoomWindow() {
        let displays = [(width: 1920.0, height: 1080.0)]
        let meeting = [ShareWindow(owner: "zoom.us", title: "Zoom Meeting", layer: 0, width: 1920, height: 1080)]
        #expect(ScreenShare.reason(processes: ["zoom.us", "replayd"], windows: meeting, displaySizes: displays) == nil)
        #expect(ScreenShare.reason(processes: ["CptHost"], windows: meeting, displaySizes: displays) == "Zoom is sharing the screen")
        #expect(ScreenShare.reason(processes: ["screencapture"], windows: [], displaySizes: displays) != nil)
        let chrome = [ShareWindow(owner: "Google Chrome", title: "meet.google.com is sharing your screen")]
        #expect(ScreenShare.reason(processes: ["Google Chrome"], windows: chrome)?.contains("sharing") == true)
        let teams = [ShareWindow(owner: "Microsoft Teams", title: "You are sharing your screen")]
        #expect(ScreenShare.reason(processes: [], windows: teams) == "Teams is sharing the screen")
        // Without Screen Recording permission, titles are redacted (""):
        // normal Teams windows (layer 0) and small floating PIPs do not trigger,
        // while Teams' elevated full-display sharing border overlay does.
        let teamsNormal = [
            ShareWindow(owner: "Microsoft Teams", title: "", layer: 0, width: 1920, height: 1080),
            ShareWindow(owner: "Microsoft Teams", title: "", layer: 3, width: 320, height: 180),
        ]
        #expect(ScreenShare.reason(processes: ["Microsoft Teams"], windows: teamsNormal, displaySizes: displays) == nil)
        let teamsRedBorder = [
            ShareWindow(owner: "Microsoft Teams", title: "", layer: 3, width: 1920, height: 1080),
        ]
        #expect(ScreenShare.reason(processes: ["Microsoft Teams"], windows: teamsRedBorder, displaySizes: displays) == "Teams is sharing the screen")
        let cptWindow = [ShareWindow(owner: "CptHost", title: "", layer: 3, width: 400, height: 60)]
        #expect(ScreenShare.reason(processes: [], windows: cptWindow, displaySizes: displays) == "Zoom is sharing the screen")
    }

    @Test func pillHidesForShareAndManualHideWithoutCaptureTricks() {
        #expect(RecordingPill.visible(recording: true, settingAllows: true, manuallyHidden: false,
                                      sessionShown: false, screenSharing: false, broughtBackDuringShare: false,
                                      callEnding: false))
        #expect(!RecordingPill.visible(recording: true, settingAllows: true, manuallyHidden: true,
                                       sessionShown: false, screenSharing: false, broughtBackDuringShare: false,
                                       callEnding: true))
        #expect(!RecordingPill.visible(recording: true, settingAllows: true, manuallyHidden: false,
                                       sessionShown: false, screenSharing: true, broughtBackDuringShare: false,
                                       callEnding: true))
        #expect(RecordingPill.visible(recording: true, settingAllows: true, manuallyHidden: false,
                                      sessionShown: false, screenSharing: true, broughtBackDuringShare: true,
                                      callEnding: false))
        #expect(RecordingPill.visible(recording: true, settingAllows: false, manuallyHidden: false,
                                      sessionShown: true, screenSharing: false, broughtBackDuringShare: false,
                                      callEnding: false))
        #expect(!RecordingPill.visible(recording: false, settingAllows: true, manuallyHidden: false,
                                       sessionShown: false, screenSharing: false, broughtBackDuringShare: false,
                                       callEnding: false))
    }

    @Test func sonnetTextCallCorrectsTheWholeDraft() throws {
        let args = HaikuBridge.textArguments(system: "correct")
        #expect(args.contains("--model") && args.contains("claude-sonnet-5-5"))
        #expect(args.contains("--input-format") && args.contains("text"))
        #expect(args.contains("--output-format") && args.contains("json"))
        #expect(args.contains("--no-session-persistence"))
        #expect(!args.contains("--bare"))
        #expect(!args.contains("stream-json"))
        #expect(!args.contains("audio"))
        #expect(args.contains("--disallowed-tools"))
        let prompt = HaikuCorrection.userPrompt([
            (index: 0, id: "speaker_1", speaker: "Priya", text: "move tree point two"),
            (index: 1, id: "you", speaker: "You", text: "the payments fix")
        ])
        #expect(prompt.contains("Entire transcript:"))
        #expect(prompt.contains("Priya"))
        #expect(prompt.contains("the payments fix"))
        #expect(!prompt.contains("audio"))
        let json = Data(#"{"is_error":false,"result":"{\"segments\":[{\"i\":0,\"text\":\"move 3.2\"}]}"}"#.utf8)
        let ok = try HaikuBridge.text(fromCLIJSON: json)
        #expect(ok.contains("move 3.2"))
        #expect(throws: HaikuBridgeError.self) {
            try HaikuBridge.text(fromCLIJSON: Data(#"{"is_error":true,"result":"401 bad sk-ant-secret"}"#.utf8))
        }
        let originals = ["the payments fix", "move tree point two"]
        let reply = """
        Sure.
        ```json
        {"segments":[{"i":1,"text":"move 3.2"}]}
        ```
        """
        let corrected = try HaikuCorrection.apply(reply: reply, originals: originals)
        #expect(corrected == ["the payments fix", "move 3.2"])
        let unchanged = try HaikuCorrection.apply(reply: #"{"segments":[]}"#, originals: originals)
        #expect(unchanged == originals)
        #expect(throws: HaikuBridgeError.badReply) {
            try HaikuCorrection.apply(reply: "not json", originals: originals)
        }
        #expect(TranscriptionEngine.resolve("haiku") == .sonnet)
        #expect(TranscriptionEngine.resolve("sonnet") == .sonnet)
        #expect(TranscriptionEngine.default == .fast)
    }
}
