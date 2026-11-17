import Foundation
import Testing
@testable import ReMeetKit

struct SpeakerTrackTests {
    @Test func micIsTheUserAndSystemSpeechIsNeverYou() {
        let plan = SpeakerTurnPlan.assemble(
            micEnergy: [(start: 0.2, end: 1.4)],
            systemEnergy: [(start: 2, end: 4), (start: 5, end: 8)],
            systemDiarized: [
                SpeechSegment(start: 2, end: 4, speaker: "you"),
                SpeechSegment(start: 5, end: 8, speaker: "S2"),
            ],
            systemEmbeddings: ["you": [1, 0], "S2": [0, 1]],
            labelSpeakers: true)
        #expect(plan.mic.map(\.speaker) == ["you"])
        #expect(plan.system.map(\.speaker) == ["speaker_1", "speaker_2"])
        #expect(plan.system.allSatisfy { $0.speaker != SpeakerNames.youID })
        #expect(plan.embeddings["speaker_1"] == [1, 0])
        #expect(plan.embeddings["speaker_2"] == [0, 1])
        #expect(plan.embeddings[SpeakerNames.youID] == nil)
    }

    @Test func distinctSystemSpeakersStayDistinct() {
        let plan = SpeakerTurnPlan.assemble(
            micEnergy: [],
            systemEnergy: [],
            systemDiarized: [
                SpeechSegment(start: 0, end: 1, speaker: "A"),
                SpeechSegment(start: 2, end: 3, speaker: "B"),
                SpeechSegment(start: 4, end: 5, speaker: "A"),
            ],
            systemEmbeddings: ["A": [1], "B": [0]],
            labelSpeakers: true)
        #expect(plan.system.map(\.speaker) == ["speaker_1", "speaker_2", "speaker_1"])
        #expect(Set(plan.system.map(\.speaker)).count == 2)
    }

    @Test func systemEnergyWithoutADiarizerIsNotTheUser() {
        let plan = SpeakerTurnPlan.assemble(
            micEnergy: [(start: 0, end: 1)],
            systemEnergy: [(start: 2, end: 3), (start: 4, end: 5)],
            systemDiarized: [],
            systemEmbeddings: [:],
            labelSpeakers: true)
        #expect(plan.mic.allSatisfy { $0.speaker == "you" })
        #expect(plan.system.allSatisfy { $0.speaker == "speaker_1" })
        #expect(plan.system.allSatisfy { $0.speaker != "you" })
    }

    @Test func labelsOffKeepTheCallSeparateFromYou() {
        let plan = SpeakerTurnPlan.assemble(
            micEnergy: [(start: 0, end: 1)],
            systemEnergy: [(start: 1, end: 2)],
            systemDiarized: [SpeechSegment(start: 1, end: 2, speaker: "you")],
            systemEmbeddings: ["you": [1, 0, 0]],
            labelSpeakers: false)
        #expect(plan.system.map(\.speaker) == ["call"])
        #expect(plan.embeddings.isEmpty)
    }

    @Test func renameChangesOneVoice() {
        let names = SpeakerNames(names: ["speaker_1": "Ada", "speaker_2": "Bo", "you": "Alex"])
        let next = names.renaming("speaker_1", to: "Ava")
        #expect(next.names["speaker_1"] == "Ava")
        #expect(next.names["speaker_2"] == "Bo")
        #expect(next.names["you"] == "Alex")
        #expect(names.names["speaker_1"] == "Ada")
        let refused = next.renaming("speaker_2", to: " You ")
        #expect(refused.names == next.names)
        let cleared = next.renaming("speaker_2", to: "  ")
        #expect(cleared.names["speaker_2"] == nil)
        #expect(cleared.names["speaker_1"] == "Ava")
    }

    @Test func aVoiceprintIsASuggestionForOneSpeaker() {
        let memory = SpeakerMemory(voices: [
            KnownVoice(name: "Ada", embedding: [1, 0, 0], seconds: 20, updated: Date()),
        ])
        let existing = SpeakerNames(names: ["speaker_2": "Bo"])
        let offered = memory.suggestions(for: [
            "speaker_1": [1, 0, 0],
            "speaker_2": [1, 0, 0],
            "speaker_3": [1, 0, 0],
        ], existing: existing)
        #expect(offered.count == 1)
        #expect(offered.first?.speaker == "speaker_1")
        #expect(offered.first?.name == "Ada")
        #expect(existing.names["speaker_1"] == nil)
        #expect(existing.names["speaker_2"] == "Bo")
        #expect(existing.names["speaker_3"] == nil)
    }

    @Test func modelsNeverSeeTheMix() {
        #expect(MeetingFolder.modelTracks == [.mic16k, .system16k])
        #expect(!MeetingFolder.modelTracks.contains(.audio))
    }

    @Test func separateTracksShareOneTimeline() {
        let stitched = Stitcher.stitch([
            TranscriptSegment(start: 1.5, end: 2.4, speaker: "speaker_1", text: "from the call", source: .system),
            TranscriptSegment(start: 1.0, end: 1.4, speaker: "you", text: "from the mic", source: .mic),
        ])
        #expect(stitched.map(\.start) == [1.0, 1.5])
        #expect(stitched.map(\.end) == [1.4, 2.4])
        #expect(stitched.map(\.speaker) == ["you", "speaker_1"])
        #expect(stitched.map(\.source) == [.mic, .system])
    }

    @Test func correctionKeepsSpeakersAndDoesNotInventLines() throws {
        #expect(HaikuCorrection.system.contains("do not give those words"))
        #expect(HaikuCorrection.system.contains("Do not merge"))
        let originals = ["the payments fix needs another weak", "move tree point two"]
        let reply = """
        {"segments":[{"i":1,"text":"Move 3.2.","speaker":"You"},{"i":0,"text":"The payments fix needs another week.","speaker":"Priya"},{"i":4,"text":"invented line"}]}
        """
        let texts = try HaikuCorrection.apply(reply: reply, originals: originals)
        #expect(texts == ["The payments fix needs another week.", "Move 3.2."])
        let segments = [
            TranscriptSegment(start: 1, end: 2, speaker: "you", text: originals[0], source: .mic),
            TranscriptSegment(start: 3, end: 4, speaker: "speaker_1", text: originals[1], source: .system),
        ]
        let corrected = zip(segments, texts).map { segment, text in
            var copy = segment
            copy.text = text
            return copy
        }
        #expect(TranscriptSpeakers.preserved(original: segments, corrected: corrected))
        #expect(corrected[0].speaker == "you")
        #expect(corrected[1].speaker == "speaker_1")
    }

    @Test func aBadCorrectionDoesNotReplaceTheDraft() {
        let originals = ["keep this"]
        #expect(throws: HaikuBridgeError.badReply) {
            try HaikuCorrection.apply(reply: "not json at all", originals: originals)
        }
    }

    @Test func accountNameBecomesTheSpellingSonnetUses() {
        #expect(RecorderName.given(stored: nil, systemFullName: "Alex Morgan") == "Alex")
        #expect(RecorderName.given(stored: " Alex ", systemFullName: "Someone Else") == "Alex")
        #expect(RecorderName.given(stored: "  ", systemFullName: "Alex Morgan") == "Alex")
        let context = NameGlossary.context(
            recorderName: "Alex",
            speakers: SpeakerNames(names: ["speaker_1": "David", "speaker_4": "David"]),
            segments: [
                TranscriptSegment(start: 0, end: 1, speaker: "you", text: "Alec will send it", source: .mic),
                TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "ok", source: .system),
                TranscriptSegment(start: 2, end: 3, speaker: "speaker_4", text: "ok", source: .system),
            ])
        #expect(context.contains("exactly \"Alex\""))
        #expect(context.contains("you: Alex"))
        #expect(context.contains("speaker_1: David"))
        #expect(context.contains("speaker_4: David"))
        #expect(context.contains("Do not merge ids"))
        let prompt = HaikuCorrection.userPrompt([
            (index: 0, id: "you", speaker: "You", text: "Alec will send it")
        ], context: context)
        #expect(prompt.contains("exactly \"Alex\""))
        #expect(prompt.contains("\"id\":\"you\""))
        #expect(prompt.contains("Entire transcript:"))
    }

    @Test func mergingTwoVoicesLeavesTheOthers() {
        let transcript = Transcript(engine: "Parakeet", segments: [
            TranscriptSegment(start: 0, end: 1, speaker: "you", text: "hello", source: .mic),
            TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "one", source: .system),
            TranscriptSegment(start: 2, end: 3, speaker: "speaker_2", text: "two", source: .system),
            TranscriptSegment(start: 3, end: 4, speaker: "speaker_1", text: "three", source: .system),
        ])
        let merged = SpeakerMerge.transcript(transcript, from: "speaker_1", into: "speaker_2")
        #expect(merged.segments.map(\.speaker) == ["you", "speaker_2", "speaker_2", "speaker_2"])
        #expect(merged.segments.map(\.text) == transcript.segments.map(\.text))
        #expect(SpeakerMerge.transcript(transcript, from: "you", into: "speaker_2").segments.map(\.speaker) == ["you", "speaker_1", "speaker_2", "speaker_1"])
        let names = SpeakerMerge.names(SpeakerNames(names: ["speaker_1": "David", "speaker_2": "David", "speaker_3": "Nico"]),
                                       from: "speaker_1", into: "speaker_2")
        #expect(names.names["speaker_1"] == nil)
        #expect(names.names["speaker_2"] == "David")
        #expect(names.names["speaker_3"] == "Nico")
        let intoYou = SpeakerMerge.names(SpeakerNames(names: ["speaker_1": "David", "you": "Alex"]),
                                         from: "speaker_1", into: "you")
        #expect(intoYou.names["you"] == "Alex")
        #expect(intoYou.names["speaker_1"] == nil)
        let diarization = Diarization(mic: [], system: [
            SpeechSegment(start: 0, end: 1, speaker: "speaker_1"),
            SpeechSegment(start: 1, end: 2, speaker: "speaker_2"),
        ], engine: "energy", embeddings: ["speaker_1": [1, 0], "speaker_2": [0, 1]])
        let moved = SpeakerMerge.diarization(diarization, from: "speaker_1", into: "speaker_2")
        #expect(moved.system.map(\.speaker) == ["speaker_2", "speaker_2"])
        #expect(moved.embeddings["speaker_1"] == nil)
        #expect(moved.embeddings["speaker_2"] == [0, 1])
    }

    @Test func aNewSplitKeepsANameOnlyWhenTheVoiceMatches() {
        let previous = SpeakerNames(names: ["you": "Alex", "speaker_1": "David", "speaker_2": "Chris", "speaker_3": "Nico"])
        let carried = SpeakerNameCarry.names(
            previous: previous,
            previousEmbeddings: ["speaker_1": [1, 0], "speaker_2": [0, 1], "speaker_3": [1, 1]],
            nextEmbeddings: ["speaker_1": [0, 1], "speaker_2": [1, 0]])
        #expect(carried.names["you"] == "Alex")
        #expect(carried.names["speaker_1"] == "Chris")
        #expect(carried.names["speaker_2"] == "David")
        #expect(carried.names["speaker_3"] == nil)
    }

    @Test func similarRowsAreOfferedAndNotMerged() {
        let pairs = SpeakerLikeness.pairs(
            ["speaker_1": [1, 0], "speaker_2": [1, 0], "speaker_3": [0, 1]],
            order: ["speaker_1", "speaker_2", "speaker_3"])
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == "speaker_2")
        #expect(pairs.first?.target == "speaker_1")
        let distinct = SpeakerLikeness.pairs(
            ["speaker_1": [1, 0], "speaker_2": [0, 1]],
            order: ["speaker_1", "speaker_2"])
        #expect(distinct.isEmpty)
    }

    @Test func clipIsOneSystemVoice() {
        let segments = [
            TranscriptSegment(start: 0, end: 12, speaker: "you", text: "me", source: .mic),
            TranscriptSegment(start: 1, end: 2, speaker: "speaker_1", text: "short", source: .system),
            TranscriptSegment(start: 4, end: 20, speaker: "speaker_1", text: "long", source: .system),
            TranscriptSegment(start: 6, end: 9, speaker: "speaker_2", text: "other", source: .system),
        ]
        let clip = SpeakerClip.excerpt(speaker: "speaker_1", segments: segments)
        #expect(clip?.start == 4)
        #expect(clip?.end == 12)
        #expect(SpeakerClip.excerpt(speaker: "you", segments: segments) == nil)
        #expect(SpeakerClip.excerpt(speaker: "speaker_2", segments: segments)?.start == 6)
    }
}
