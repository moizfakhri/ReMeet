import Foundation
import Testing
@testable import ReMeetKit

struct NotesTests {
    @Test func timestampIsWhenFieldOpened() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(NoteTiming.timestamp(openedAt: start.addingTimeInterval(754.27), recordingStart: start) == 754.3)
        #expect(NoteTiming.timestamp(openedAt: start.addingTimeInterval(-2), recordingStart: start) == 0)
    }

    @Test func submitKinds() {
        #expect(NoteTiming.resolve(text: "  ", command: false, t: 1).kind == .bookmark)
        #expect(NoteTiming.resolve(text: "", command: true, t: 1).kind == .bookmark)
        let note = NoteTiming.resolve(text: " Ask Tom about refunds \n", command: false, t: 2)
        #expect(note.kind == .note && note.text == "Ask Tom about refunds")
        #expect(NoteTiming.resolve(text: "Send deck", command: true, t: 3).kind == .action)
        #expect(MeetingNote(t: 0, text: "", kind: .bookmark).displayText == "Bookmark")
    }

    @Test func appendKeepsOrderAndSurvivesReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = NotesFile(url: url)
        #expect(file.load().isEmpty)
        try file.append(MeetingNote(t: 30, text: "b", kind: .note))
        try file.append(MeetingNote(t: 10, text: "a", kind: .action))
        try file.append(MeetingNote(t: 20, text: "", kind: .bookmark))
        let loaded = NotesFile(url: url).load()
        #expect(loaded.map(\.t) == [10, 20, 30])
        #expect(loaded.map(\.kind) == [.action, .bookmark, .note])
    }

    @Test func notesDecodeWithoutOptionalFields() throws {
        let json = #"[{"t": 12.5, "text": "hi"}, {"t": 3, "kind": "bookmark"}]"#
        let notes = try JSONCoding.decoder().decode([MeetingNote].self, from: Data(json.utf8))
        #expect(notes[0].kind == .note && notes[1].text == "")
    }
}

struct TimeFormatTests {
    @Test func formats() {
        #expect(TimeFormat.clock(754.9) == "12:34")
        #expect(TimeFormat.clock(3723) == "1:02:03")
        #expect(TimeFormat.timer(3723) == "01:02:03")
        #expect(TimeFormat.duration(40) == "40 s")
        #expect(TimeFormat.duration(48 * 60 + 10) == "48 min")
        #expect(TimeFormat.duration(72 * 60) == "1 h 12 min")
        #expect(TimeFormat.duration(120 * 60) == "2 h")
        #expect(TimeFormat.parseClock("12:34") == 754)
        #expect(TimeFormat.parseClock("1:02:03") == 3723)
        #expect(TimeFormat.parseClock("ab") == nil)
    }
}

struct WAVRepairTests {
    /// A 16-bit mono WAV whose header claims 0 data bytes, as left behind by a crash.
    private func makeTruncatedWAV(samples: Int, withJunk: Bool) throws -> URL {
        var data = Data("RIFF".utf8) + le32(0) + Data("WAVE".utf8)
        if withJunk { data += Data("JUNK".utf8) + le32(3) + Data([0, 0, 0, 0]) }  // odd size + pad byte
        data += Data("fmt ".utf8) + le32(16)
        data += le16(1) + le16(1) + le32(48_000) + le32(96_000) + le16(2) + le16(16)
        data += Data("data".utf8) + le32(0)
        data += Data(repeating: 0x11, count: samples * 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID()).wav")
        try data.write(to: url)
        return url
    }

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    @Test(arguments: [false, true])
    func repairsSizes(withJunk: Bool) throws {
        let url = try makeTruncatedWAV(samples: 4800, withJunk: withJunk)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try WAVRepair.repair(url)
        #expect(result == .init(repaired: true, dataBytes: 9600))
        let data = try Data(contentsOf: url)
        let riff = data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(riff) == data.count - 8)
        // Second run finds nothing to fix.
        #expect(try WAVRepair.repair(url).repaired == false)
    }

    @Test func rejectsNonWAV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID()).wav")
        try Data("hello world!".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: WAVRepair.RepairError.notRIFF) { try WAVRepair.repair(url) }
    }
}
