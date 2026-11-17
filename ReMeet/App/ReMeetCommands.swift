import AppKit
import KeyboardShortcuts
import ReMeetKit
import SwiftUI

/// What the menu bar menus act on: the meeting open in the focused meeting window.
struct MeetingFocus {
    var document: MeetingDocument?
    var showTranscript: Binding<Bool>
}

extension FocusedValues {
    @Entry var meetingFocus: MeetingFocus?
}

/// Sidebar actions the menus ask for (rename and delete need the sidebar's alerts).
enum SidebarRequest: Equatable {
    case rename(MeetingFolder)
    case trash(MeetingFolder)
    case newFolder
}

/// The menu bar menus. ReMeet is a menu bar app, but while a window is open the standard
/// menus show; these give every action a place there (with shortcuts) instead of the
/// mostly empty defaults.
struct ReMeetCommands: Commands {
    @FocusedValue(\.meetingFocus) private var focus
    private var model: AppModel { AppModel.shared }

    var body: some Commands {
        // File: recording and organizing, where New usually is.
        CommandGroup(replacing: .newItem) {
            // The global shortcuts work in every app, so they are shown in the title rather
            // than bound here (a menu key equivalent would only work while ReMeet is in front).
            Button((model.recorder.isRecording ? "Stop Recording" : "Start Recording") + hint(.toggleRecording)) {
                model.toggleRecording()
            }
            Button("Add Note" + hint(.addNote)) { model.addNoteShortcut() }
                .disabled(!model.recorder.isRecording)
            Divider()
            Button("Open Meetings") { model.openMeetings() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Import Audio…") { model.importMeetingAudioChosen() }
            Button("New Folder…") {
                model.openMeetings()
                model.sidebarRequest = .newFolder
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
        }

        CommandMenu("Meeting") {
            let document = focus?.document
            Button("Copy for AI") { if let document { AIClipboard.copy(document) } }
                .keyboardShortcut("c", modifiers: [.shift, .command])
                .disabled(document == nil)
            Button("Copy Summary") { if let document { SummaryClipboard.copy(document) } }
                .keyboardShortcut("c", modifiers: [.option, .shift, .command])
                .disabled(document?.summary == nil)
            Menu("Regenerate") {
                RegenerateMenuContent(document: document)
            }
            .disabled(document == nil)
            Divider()
            Button("Rename…") { if let document { model.sidebarRequest = .rename(document.folder) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(document == nil)
            Menu("Move to Folder") {
                Button("No Folder") { if let document { model.library.move(document.folder, to: nil) } }
                    .disabled(document?.meta.collectionID == nil)
                if !model.library.collections.isEmpty { Divider() }
                ForEach(model.library.collections) { folder in
                    Button(folder.name) { if let document { model.library.move(document.folder, to: folder.id) } }
                        .disabled(document?.meta.collectionID == folder.id)
                }
            }
            .disabled(document == nil)
            Button("Reveal in Finder") {
                if let document { NSWorkspace.shared.activateFileViewerSelecting([document.folder.url]) }
            }
            .disabled(document == nil)
            Button("Reveal Original Audio") {
                if let urls = document?.folder.originalAudioURLs(), !urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            .disabled(document?.folder.originalAudioURLs().isEmpty != false)
            Button("Reprocess") { if let document { model.reprocess(document.folder) } }
                .disabled(document == nil || document?.meta.status == .recording)
            Divider()
            Button("Move to Trash…") { if let document { model.sidebarRequest = .trash(document.folder) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(document == nil || document?.meta.status == .recording)
        }

        CommandGroup(before: .sidebar) {
            Button(focus?.showTranscript.wrappedValue == true ? "Hide Transcript" : "Show Transcript") {
                focus?.showTranscript.wrappedValue.toggle()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(focus == nil)
            Button("Find in Transcript") {
                focus?.showTranscript.wrappedValue = true
                model.transcriptFindPending = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focus?.document?.transcript == nil)
            Button("Focus Chat") { model.focusChat() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(focus?.document == nil)
            Divider()
        }
    }

    private func hint(_ name: KeyboardShortcuts.Name) -> String {
        let text = name.hint
        return text.isEmpty ? "" : "  (\(text))"
    }
}
