import AppKit
import KeyboardShortcuts
import ReMeetKit
import SwiftUI

enum MomentFilterOption: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"
    case decisions = "Decisions"
    case commitments = "Commitments"
    case takeaways = "Key Points"

    var id: String { rawValue }

    func matches(_ kind: KeyMoment.Kind) -> Bool {
        switch self {
        case .all: true
        case .pinned: kind == .pinned
        case .decisions: kind == .decision
        case .commitments: kind == .commitment
        case .takeaways: kind == .takeaway || kind == .question
        }
    }
}

/// Sidebar list for the Moments tab: category filter + compact moment rows across all recordings.
struct MomentsSidebarContent: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedCategory: MomentFilterOption
    @Binding var selectedMomentID: String?
    let search: String
    let onOpenInMeeting: (MeetingFolder, Double) -> Void

    var filteredMoments: [GlobalMomentItem] {
        var list = model.hub.moments.filter { selectedCategory.matches($0.moment.kind) }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.moment.title.localizedCaseInsensitiveContains(q)
                    || $0.moment.quote.localizedCaseInsensitiveContains(q)
                    || ($0.moment.speakerName?.localizedCaseInsensitiveContains(q) == true)
                    || $0.meetingTitle.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var body: some View {
        List {
            Section {
                ForEach(MomentFilterOption.allCases) { option in
                    let count = model.hub.moments.filter { option.matches($0.moment.kind) }.count
                    let active = selectedCategory == option
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: option))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(active ? Theme.accent : Theme.fg2)
                            .frame(width: 18)
                        Text(option.rawValue)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Theme.accent : Theme.fg)
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Theme.fg2)
                    }
                    .sidebarRow(selected: active) {
                        selectedCategory = option
                    }
                }
            } header: {
                Text("Filter Moments")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.fg3)
                    .textCase(nil)
            }

            if !filteredMoments.isEmpty {
                Section {
                    ForEach(filteredMoments.prefix(40)) { item in
                        let selected = selectedMomentID == item.id
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.moment.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(selected ? Theme.accent : Theme.fg)
                                .lineLimit(2)
                            Text("\(item.meetingTitle) · \(TimeFormat.clock(item.moment.startTime))")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.fg2)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .sidebarRow(selected: selected) {
                            selectedMomentID = item.id
                        }
                        .contextMenu {
                            Button("Open in Meeting") {
                                onOpenInMeeting(item.folder, item.moment.startTime)
                            }
                        }
                    }
                } header: {
                    Text("Recent Moments")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func symbol(for option: MomentFilterOption) -> String {
        switch option {
        case .all: "sparkles.rectangle.stack"
        case .pinned: "pin.fill"
        case .decisions: "checkmark.seal.fill"
        case .commitments: "arrow.right.circle.fill"
        case .takeaways: "sparkles"
        }
    }
}

/// Detail gallery for the Moments tab: grid of Key Moment Tile Cards across every recorded meeting.
struct MomentsGalleryView: View {
    @Environment(AppModel.self) private var model
    let category: MomentFilterOption
    let selectedMomentID: String?
    let search: String
    let onOpenInMeeting: (MeetingFolder, Double) -> Void

    @State private var clipPlayer = ExcerptAudioPlayer()
    @State private var copiedID: String?

    private var items: [GlobalMomentItem] {
        var list = model.hub.moments.filter { category.matches($0.moment.kind) }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.moment.title.localizedCaseInsensitiveContains(q)
                    || $0.moment.quote.localizedCaseInsensitiveContains(q)
                    || ($0.moment.speakerName?.localizedCaseInsensitiveContains(q) == true)
                    || $0.meetingTitle.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var body: some View {
        ScrollViewReader { proxy in
            ResponsiveDocumentScroll(maxWidth: 760, topPadding: 24, bottomPadding: 48) { _ in
                VStack(alignment: .leading, spacing: 20) {
                    Text(category == .all ? "Key Moments" : category.rawValue)
                        .font(Fonts.title)
                        .foregroundStyle(Theme.fg)

                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(Theme.fg3)
                            Text("No moments in this view yet")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.fg)
                            Text("Press \(KeyboardShortcutsHint.markMoment) during a call to mark a moment.")
                                .font(.callout)
                                .foregroundStyle(Theme.fg2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12, alignment: .top)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(items) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button {
                                        onOpenInMeeting(entry.folder, entry.moment.startTime)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(entry.meetingTitle)
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundStyle(Theme.fg2)
                                                .lineLimit(1)
                                            Text("·")
                                                .foregroundStyle(Theme.fg3)
                                            Text(entry.meetingDate.formatted(.dateTime.month(.abbreviated).day()))
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Theme.fg3)
                                            Spacer()
                                            Image(systemName: "arrow.up.right")
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .foregroundStyle(Theme.fg3)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 4)

                                    MomentTileCard(
                                        moment: entry.moment,
                                        meetingSubtitle: entry.meetingTitle,
                                        isPlaying: clipPlayer.playingID == entry.id,
                                        isCopied: copiedID == entry.id,
                                        hasAudio: entry.hasAudio,
                                        onPlayClip: {
                                            if entry.hasAudio {
                                                clipPlayer.toggle(
                                                    id: entry.id,
                                                    audioURL: entry.folder.file(.audio),
                                                    start: entry.moment.startTime,
                                                    end: entry.moment.endTime
                                                )
                                            } else {
                                                onOpenInMeeting(entry.folder, entry.moment.startTime)
                                            }
                                        },
                                        onJumpTranscript: {
                                            clipPlayer.stop()
                                            onOpenInMeeting(entry.folder, entry.moment.startTime)
                                        },
                                        onCopyQuote: {
                                            let md = entry.moment.markdownCard(meetingTitle: entry.meetingTitle,
                                                                               meetingDate: entry.meetingDate)
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(md, forType: .string)
                                            copiedID = entry.id
                                            Task {
                                                try? await Task.sleep(for: .seconds(1.5))
                                                if copiedID == entry.id { copiedID = nil }
                                            }
                                        },
                                        onOpenSpeaker: { name in
                                            clipPlayer.stop()
                                            model.openPerson(named: name)
                                        }
                                    )
                                }
                                .id(entry.id)
                            }
                        }
                    }
                }
            }
            .onDisappear { clipPlayer.stop() }
            .onChange(of: selectedMomentID) { _, id in
                if let id {
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private enum KeyboardShortcutsHint {
    static var markMoment: String {
        let hint = KeyboardShortcuts.Name.markMoment.hint
        return hint.isEmpty ? "⌥⌘M" : hint
    }
}
