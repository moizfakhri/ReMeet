import AppKit
import KeyboardShortcuts
import ReMeetKit
import SwiftUI

/// "Recording now" in the sidebar: title, timer, levels and the notes taken so far.
struct LiveRecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.recording).frame(width: 10, height: 10)
                    Text(recorder.title).font(Fonts.title)
                }
                Text(TimeFormat.timer(recorder.elapsed))
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("You").font(.caption).foregroundStyle(Theme.fg2)
                        LevelBars(level: recorder.micLevel, count: 24).frame(height: 12)
                    }
                    VStack(alignment: .leading) {
                        Text("Call").font(.caption).foregroundStyle(Theme.fg2)
                        LevelBars(level: recorder.systemLevel, count: 24).frame(height: 12)
                    }
                }
                if !recorder.notes.isEmpty {
                    SectionHeader(title: "Your notes")
                    ForEach(recorder.notes) { note in
                        HStack(spacing: 12) {
                            Text(TimeFormat.clock(note.t)).font(Fonts.monoSmall).foregroundStyle(Theme.accent)
                            Text(note.displayText)
                            if note.kind == .action { NoteKindBadge(text: "Action") }
                        }
                    }
                }
                HStack {
                    Button("Add note  \(KeyboardShortcuts.Name.addNote.hint)") { model.addNoteShortcut() }
                        .buttonStyle(.glass)
                    Button("Stop  \(KeyboardShortcuts.Name.toggleRecording.hint)") { recorder.stop() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.recordingFill)
                }
                Text("The transcript and summary are made after you stop, on this Mac.")
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
    }
}

/// Copy for AI (⇧⌘C): the meeting as plain Markdown (header, your notes, summary if any,
/// the whole transcript) to paste into any AI chat as context.
enum AIClipboard {
    @MainActor
    static func copy(_ document: MeetingDocument) {
        put(AIContextMarkdown.render(meta: document.meta, transcript: document.transcript, notes: document.notes,
                                     summary: document.summary, speakers: document.speakers,
                                     collection: collection(for: document.folder, meta: document.meta)))
    }

    /// From the sidebar, without opening the meeting: files are read off the main thread.
    @MainActor
    static func copy(_ folder: MeetingFolder) async {
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let c = MeetingDocument.Contents.read(folder) else { return nil }
            return AIContextMarkdown.render(meta: c.meta, transcript: c.transcript, notes: c.notes,
                                            summary: c.summary, speakers: c.speakers,
                                            collection: collection(for: folder, meta: c.meta))
        }.value
        if let text { put(text) }
    }

    nonisolated private static func collection(for folder: MeetingFolder, meta: MeetingMeta) -> MeetingCollection? {
        guard let id = meta.collectionID else { return nil }
        return CollectionsFile(for: folder).load().first { $0.id == id }
    }

    @MainActor
    private static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Copy summary (⌥⇧⌘C): the summary as Markdown on the clipboard.
enum SummaryClipboard {
    @MainActor
    static func copy(_ document: MeetingDocument) {
        guard let summary = document.summary else { return }
        let markdown = SummaryMarkdown.render(summary, meta: document.meta, notes: document.notes)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

/// Toolbar Regenerate: redo the transcript from the recording, or write the summary again.
struct RegenerateMenu: View {
    let document: MeetingDocument?

    var body: some View {
        Menu {
            RegenerateMenuContent(document: document)
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .help("Redo the transcript from the recording, or write the summary again. Stop is on the meeting while a run is going.")
        .disabled(document == nil)
    }
}

struct RegenerateMenuContent: View {
    /// The Meeting menu builds this during launch, before any window has installed
    /// `AppModel` in the environment. Reading `@Environment` there traps and the app never opens.
    private var model: AppModel { AppModel.shared }
    let document: MeetingDocument?

    private var canRedoTranscription: Bool {
        guard let document, document.meta.status != .recording else { return false }
        return document.reprocessStart < .summarize
    }

    private var canFindSpeakers: Bool {
        guard let document, document.meta.status != .recording else { return false }
        return document.reprocessStart < .transcribe
    }

    private var canRegenerateSummary: Bool {
        document?.meta.completedStages.contains(.transcribe) == true && document?.meta.status != .recording
    }

    var body: some View {
        Section("Transcription") {
            Button("Redo with Parakeet") { redo(.fast) }
                .disabled(!canRedoTranscription)
                .help("Reads the recording again and keeps the current speaker split. The summary is written again afterward.")
            Button("Redo with Cohere") { redo(.accurate) }
                .disabled(!canRedoTranscription)
                .help("Reads the recording again and keeps the current speaker split. The summary is written again afterward.")
        }
        Section("Speakers") {
            Button("Find speakers again") {
                if let document { model.findSpeakersAgain(document) }
            }
            .disabled(!canFindSpeakers)
            .help("Splits the call voices again. A name stays with a person only when the new voice still matches. This does not run when you only rename someone.")
        }
        Section("Summary") {
            ForEach(SummaryBackendKind.allCases) { backend in
                Button(backend.menuTitle) {
                    if let document { model.regenerateSummary(document.folder, backend: backend) }
                }
                .disabled(!canRegenerateSummary)
            }
        }
    }

    private func redo(_ engine: TranscriptionEngine) {
        guard let document else { return }
        model.applyTranscriptionEngine(document, engine: engine)
    }
}

/// Meeting apps ReMeet knows by bundle identifier.
enum MeetingApps {
    static let known: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.google.Chrome": "Google Meet",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
    ]

    static func displayName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return known[bundleID]
    }
}
