import Foundation

/// A meeting's folder, `~/ReMeet/meetings/<yyyy-MM-dd_HHmm>_<slug>/`, and the files in it.
/// The folder name is fixed when recording starts; later renames only change meta.json.
public struct MeetingFolder: Hashable, Sendable, Identifiable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var id: String { url.lastPathComponent }
    public var name: String { url.lastPathComponent }

    public enum File: String, CaseIterable, Sendable {
        case meta = "meta.json"
        case micWAV = "mic.wav"
        case systemWAV = "system.wav"
        case audio = "audio.m4a"
        case mic16k = "mic-16k.m4a"
        case system16k = "system-16k.m4a"
        case notes = "notes.json"
        case speakers = "speakers.json"
        case diarization = "diarization.json"
        case transcript = "transcript.json"
        case transcriptMarkdown = "transcript.md"
        case summary = "summary.json"
        case summaryMarkdown = "summary.md"
    }

    /// 16 kHz tracks a local speech model may open. `audio.m4a` is the playback mix and is not here.
    public static let modelTracks: [File] = [.mic16k, .system16k]

    public func file(_ file: File) -> URL { url.appendingPathComponent(file.rawValue) }

    public func exists(_ file: File) -> Bool {
        FileManager.default.fileExists(atPath: self.file(file).path)
    }

    /// The recorder's WAV tracks when they are still on disk, otherwise the compressed audio.
    public func originalAudioURLs() -> [URL] {
        let wavs = [File.micWAV, .systemWAV].filter(exists).map { file($0) }
        if !wavs.isEmpty { return wavs }
        return [File.audio, .mic16k, .system16k].filter(exists).map { file($0) }
    }

    // MARK: - Naming

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ReMeet/meetings", isDirectory: true)

    /// `2026-11-02_1752_weekly-sync`, plus `-2`, `-3` ... if that name is taken.
    public static func makeNew(in root: URL, start: Date, title: String,
                               timeZone: TimeZone = .current) -> MeetingFolder {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d-%02d-%02d_%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        let base = "\(stamp)_\(slug(title))"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return MeetingFolder(url: candidate)
    }

    /// Lowercase ASCII words joined by hyphens, at most 40 characters; "meeting" if empty.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? word : slug + "-" + word
            if next.count > 40 { break }
            slug = next
        }
        if slug.isEmpty, let first = words.first { slug = String(first.prefix(40)) }
        return slug.isEmpty ? "meeting" : slug.lowercased()
    }

    // MARK: - Reading and writing

    public func readMeta() throws -> MeetingMeta {
        try JSONCoding.read(MeetingMeta.self, from: file(.meta))
    }

    /// Serializes meta.json writes in this process: pipeline stages update it on background
    /// threads while the UI renames or regenerates on main (audit H1).
    private static let metaLock = NSRecursiveLock()

    /// Always writes the current schema version: a rewritten file is a current-schema file.
    public func writeMeta(_ meta: MeetingMeta) throws {
        var meta = meta
        meta.schemaVersion = MeetingMeta.currentSchemaVersion
        try Self.metaLock.withLock { try JSONCoding.write(meta, to: file(.meta)) }
    }

    /// Read-modify-write of meta.json, atomic with respect to other writers in the app.
    @discardableResult
    public func updateMeta(_ change: (inout MeetingMeta) -> Void) throws -> MeetingMeta {
        try Self.metaLock.withLock {
            var meta = try readMeta()
            change(&meta)
            try writeMeta(meta)
            return meta
        }
    }

    public func read<T: Decodable>(_ type: T.Type, _ file: File) throws -> T? {
        guard exists(file) else { return nil }
        return try JSONCoding.read(type, from: self.file(file))
    }

    public func write<T: Encodable>(_ value: T, _ file: File) throws {
        try JSONCoding.write(value, to: self.file(file))
    }

    public func writeText(_ text: String, _ file: File) throws {
        try Data(text.utf8).write(to: self.file(file), options: .atomic)
    }

    /// Re-renders `transcript.md` and `summary.md` from the current JSON files after an edit or rename.
    public func rewriteMarkdown() {
        guard let meta = try? readMeta() else { return }
        let notes = NotesFile(url: file(.notes)).load()
        if let transcript = (try? read(Transcript.self, .transcript)) ?? nil {
            let speakers = ((try? read(SpeakerNames.self, .speakers)) ?? nil) ?? SpeakerNames()
            try? writeText(TranscriptMarkdown.render(transcript, notes: notes, speakers: speakers,
                                                     title: meta.title), .transcriptMarkdown)
        }
        if let summary = (try? read(MeetingSummary.self, .summary)) ?? nil {
            try? writeText(SummaryMarkdown.render(summary, meta: meta, notes: notes), .summaryMarkdown)
        }
    }

    /// Every meeting folder under `root` that has a meta.json, newest first by name.
    public static func scan(root: URL) -> [MeetingFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted(by: >).compactMap { name in
            let folder = MeetingFolder(url: root.appendingPathComponent(name, isDirectory: true))
            return folder.exists(.meta) ? folder : nil
        }
    }
}
