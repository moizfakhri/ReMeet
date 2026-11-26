import AppKit
import ReMeetKit
import SwiftUI

enum ScheduleSelection: Hashable {
    case weekOverview
    case commitmentsRadar
    case event(String)
}

/// Sidebar list for the Schedule tab: Promises Radar entry + Apple/Google Calendar meetings.
struct ScheduleSidebarContent: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: ScheduleSelection?
    let search: String
    @State private var showingAddICS = false

    private var filteredEvents: [CalendarMeeting] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = model.calendar.events.filter { MeetingReminder.hasOnlineMeetingPlatform($0) }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.attendeeNames.contains(where: { $0.localizedCaseInsensitiveContains(q) })
                || ($0.calendarName?.localizedCaseInsensitiveContains(q) == true)
                || $0.notes.localizedCaseInsensitiveContains(q)
        }
    }

    private var groupedSchedule: [(title: String, events: [CalendarMeeting])] {
        let now = Date()
        let cal = Calendar.current
        let upcoming = filteredEvents.filter { $0.end >= now }.sorted { $0.start < $1.start }
        let past = filteredEvents.filter { $0.end < now }.sorted { $0.start > $1.start }

        var sections: [(String, [CalendarMeeting])] = []
        let today = upcoming.filter { cal.isDateInToday($0.start) }
        if !today.isEmpty { sections.append(("Today", today)) }

        let tomorrow = upcoming.filter { cal.isDateInTomorrow($0.start) }
        if !tomorrow.isEmpty { sections.append(("Tomorrow", tomorrow)) }

        let weekEnd = cal.date(byAdding: .day, value: 7, to: now) ?? now
        let thisWeek = upcoming.filter { !cal.isDateInToday($0.start) && !cal.isDateInTomorrow($0.start) && $0.start <= weekEnd }
        if !thisWeek.isEmpty { sections.append(("Next 7 Days", thisWeek)) }

        let later = upcoming.filter { $0.start > weekEnd }
        if !later.isEmpty { sections.append(("Later", Array(later.prefix(25)))) }

        if !past.isEmpty { sections.append(("Recent Past", Array(past.prefix(15)))) }
        return sections
    }

    private var openCommitmentsCount: Int {
        model.hub.commitments.filter {
            !$0.actionItem.done && $0.ageDays <= 30 && ($0.relevance == .mine || $0.relevance == .relatedToMe)
        }.count
    }

    private var defaultFocusWindow: ScheduleWeekFocus.FocusWindow {
        ScheduleWeekFocus.defaultFocus(now: Date(), events: model.calendar.events)
    }

    private var focusRemainingCount: Int {
        let win = defaultFocusWindow
        let now = Date()
        return filteredEvents.filter { $0.end >= now && $0.start < win.weekEnd && $0.end > win.weekStart }.count
    }

    var body: some View {
        List {
            Section {
                let weekSelected = selection == .weekOverview || selection == nil
                HStack(spacing: 9) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(weekSelected ? Theme.accent : Theme.fg2)
                        .frame(width: 20)
                    Text(defaultFocusWindow.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(weekSelected ? Theme.accent : Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if focusRemainingCount > 0 {
                        Text("\(focusRemainingCount)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Theme.mark, in: Capsule())
                    }
                }
                .sidebarRow(selected: weekSelected) {
                    selection = .weekOverview
                }
                .help("Integrated week & month calendar with priority action items")

                let radarSelected = selection == .commitmentsRadar
                HStack(spacing: 9) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(radarSelected ? Theme.accent : Theme.fg2)
                        .frame(width: 20)
                    Text("Commitments")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(radarSelected ? Theme.accent : Theme.fg)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if openCommitmentsCount > 0 {
                        Text("\(openCommitmentsCount)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Theme.mark, in: Capsule())
                    }
                }
                .sidebarRow(selected: radarSelected) {
                    selection = .commitmentsRadar
                }
                .help("Action items assigned to you and items waiting on others")
            }

            if !CalendarWatcher.hasAccess && model.calendar.icsFeeds.isEmpty && model.calendar.source == nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Apple or Google Calendar")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                        Text("Sync all your upcoming meetings, get Walk-In Prep Briefs, and boost speaker recognition with attendee lists.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Allow Calendar") {
                                Task {
                                    if await model.calendar.requestAccess() {
                                        model.calendar.start()
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accentFill)
                            .controlSize(.small)

                            Button("Add Google .ics…") { showingAddICS = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(groupedSchedule, id: \.title) { section in
                Section {
                    ForEach(section.events) { event in
                        let isSelected = selection == .event(event.id)
                        let recorded = matchedRecording(for: event) != nil
                        ScheduleEventRow(event: event, isSelected: isSelected, isRecorded: recorded)
                            .sidebarRow(selected: isSelected) {
                                selection = .event(event.id)
                            }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg3)
                            .textCase(nil)
                        Spacer()
                        if section.title == groupedSchedule.first?.title {
                            headerControls
                        }
                    }
                }
            }

            if groupedSchedule.isEmpty && (CalendarWatcher.hasAccess || !model.calendar.icsFeeds.isEmpty) {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Text(search.isEmpty ? "No upcoming online meetings" : "No matching online meetings")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.fg2)
                            Button("Add Google / iCal .ics URL…") { showingAddICS = true }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        .padding(.vertical, 18)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showingAddICS) {
            AddICSFeedSheet { name, url in
                _ = model.calendar.addICSFeed(name: name, urlString: url)
                model.calendarRemindersChanged()
            }
        }
    }

    private var headerControls: some View {
        HStack(spacing: 6) {
            if model.calendar.isSyncingICS {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    model.calendar.syncICSFeedsNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                        .hitTarget(4)
                }
                .buttonStyle(.plain)
                .help("Sync calendars now")
            }
            Button {
                showingAddICS = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.fg2)
                    .hitTarget(4)
            }
            .buttonStyle(.plain)
            .help("Subscribe to a Google Calendar or iCal .ics URL")
        }
    }

    private func matchedRecording(for event: CalendarMeeting) -> MeetingItem? {
        model.library.items.first { item in
            if item.meta.calendarEventID == event.id { return true }
            return abs(item.meta.startTime.timeIntervalSince(event.start)) <= 20 * 60
                && MeetingReminder.seriesKey(for: item.meta.title) == event.seriesKey
        }
    }
}

private struct ScheduleEventRow: View {
    let event: CalendarMeeting
    let isSelected: Bool
    let isRecorded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isRecorded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .help("Recorded in ReMeet")
                }
            }
            HStack(spacing: 5) {
                Text(timeLine)
                    .monospacedDigit()
                if let service = event.callService {
                    Text("·").foregroundStyle(Theme.fg3)
                    Text(service)
                } else if !event.attendeeNames.isEmpty {
                    Text("·").foregroundStyle(Theme.fg3)
                    Text("\(event.attendeeNames.count + 1)p")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.fg2)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var timeLine: String {
        let cal = Calendar.current
        if cal.isDateInToday(event.start) {
            return event.start.formatted(date: .omitted, time: .shortened)
        }
        return event.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Calendar Event Detail & Walk-In Prep Brief View

struct CalendarEventDetailView: View {
    @Environment(AppModel.self) private var model
    let event: CalendarMeeting
    var onBackToWeek: (() -> Void)? = nil
    let onOpenMeeting: (MeetingFolder, Double?) -> Void

    @State private var copiedBrief = false
    @State private var showingSoundCheck = false

    private var brief: MeetingPrepBrief {
        model.hub.prepBrief(for: event, recorderName: AppModel.recorderName)
    }

    private var linkedRecording: MeetingItem? {
        model.library.items.first { item in
            if item.meta.calendarEventID == event.id { return true }
            return abs(item.meta.startTime.timeIntervalSince(event.start)) <= 20 * 60
                && MeetingReminder.seriesKey(for: item.meta.title) == event.seriesKey
        }
    }

    var body: some View {
        let prep = brief
        ResponsiveDocumentScroll(maxWidth: 660, topPadding: 24, bottomPadding: 48) { _ in
            VStack(alignment: .leading, spacing: 22) {
                if let onBackToWeek {
                    Button(action: onBackToWeek) {
                        Label("Back to Week", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                eventHeader(prep: prep)

                if let recorded = linkedRecording {
                    recordedBanner(recorded)
                }

                attendeesSection(prep: prep)

                if !prep.yourOpenPromises.isEmpty || !prep.theirOpenPromises.isEmpty {
                    promisesOnTheTableSection(prep: prep)
                }

                if let last = prep.lastSeriesMeeting {
                    lastMeetingRecapCard(last)
                }

                if !prep.carryoverQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Carryover open questions")
                        ForEach(prep.carryoverQuestions) { q in
                            Text("• \(q.text)")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.fg2)
                        }
                    }
                }

                if !event.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Calendar invite notes")
                        Text(event.notes)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.fg2)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    }
                }
            }
        }
        .sheet(isPresented: $showingSoundCheck) {
            SoundCheckSheet()
        }
    }

    private func eventHeader(prep: MeetingPrepBrief) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WrappingFlowLayout(spacing: 8, lineSpacing: 6) {
                if let calName = event.calendarName, !calName.isEmpty {
                    Label(calName, systemImage: event.sourceKind == .icsFeed ? "globe" : "calendar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.bg, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                }
                if let service = event.callService {
                    Text(service)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.mark, in: Capsule())
                }
            }

            Text(event.title)
                .font(Fonts.title)
                .foregroundStyle(Theme.fg)

            Text("\(event.start.formatted(date: .complete, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.fg2)

            WrappingFlowLayout(spacing: 8, lineSpacing: 8) {
                if !model.recorder.isRecording {
                    if event.joinURL != nil {
                        AccentCapsuleButton(title: "Join & Record", systemImage: "video.fill") {
                            model.joinAndRecord(event)
                        }
                    }
                    Button {
                        model.startRecording(for: model.activeMeetingApp, event: event)
                    } label: {
                        Label("Record in ReMeet", systemImage: "record.circle")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        showingSoundCheck = true
                    } label: {
                        Label("Sound Check", systemImage: "waveform.badge.magnifyingglass")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }

                if let url = event.joinURL, model.recorder.isRecording {
                    Button("Open Call Link") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prep.markdown(), forType: .string)
                    copiedBrief = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedBrief = false
                    }
                } label: {
                    Label(copiedBrief ? "Copied Brief" : "Copy Brief",
                          systemImage: copiedBrief ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("Copy Walk-In Prep Brief as Markdown")
            }
            .padding(.top, 2)
        }
    }

    private func recordedBanner(_ item: MeetingItem) -> some View {
        Button {
            onOpenMeeting(item.folder, nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recorded: \(item.meta.title)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Open summary & transcript")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg2)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(Theme.mark, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func attendeesSection(prep: MeetingPrepBrief) -> some View {
        let dedupedAttendees: [(attendee: CalendarAttendee, matched: PersonSummary?)] = {
            var seenProfileIDs: Set<String> = []
            var seenNames: [String] = []
            var out: [(CalendarAttendee, PersonSummary?)] = []
            for att in event.attendees where att.status != .declined {
                let matched = prep.matchedPeople.first { $0.profile.matchesAttendee(att) }
                if let m = matched {
                    guard !seenProfileIDs.contains(m.id) else { continue }
                    seenProfileIDs.insert(m.id)
                    out.append((att, m))
                } else {
                    let display = PersonName.parse(att.name).canonicalDisplayName
                    guard !seenNames.contains(where: { SpeakerMemory.namesMatch($0, display) }) else { continue }
                    seenNames.append(display)
                    out.append((att, nil))
                }
            }
            return out
        }()
        if !dedupedAttendees.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "People on the invite (\(dedupedAttendees.count))")
                    .help("Invitees automatically boost speaker voiceprint recognition and prefill names")

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 360), spacing: 10, alignment: .top)],
                    spacing: 10
                ) {
                    ForEach(dedupedAttendees, id: \.attendee.id) { entry in
                        let att = entry.attendee
                        let matched = entry.matched
                        let displayName = matched?.profile.name ?? PersonName.parse(att.name).canonicalDisplayName
                        Button {
                            model.openPerson(named: displayName)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                PersonAvatarView(name: displayName,
                                                 size: 34,
                                                 hasVoiceprint: matched?.hasVoiceprint ?? false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.fg)
                                        .lineLimit(1)
                                    Text(matched?.profile.subtitle ?? att.inferredOrganization ?? att.email ?? att.status.rawValue.capitalized)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.fg2)
                                        .lineLimit(1)
                                    if let m = matched, !m.profile.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(m.profile.notes)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.fg3)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    } else if let m = matched, m.meetingsCount > 0 {
                                        Text("\(m.meetingsCount) prior call\(m.meetingsCount == 1 ? "" : "s")\(m.hasVoiceprint ? " · Voice ready" : "")")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func promisesOnTheTableSection(prep: MeetingPrepBrief) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                SectionHeader(title: "Walk-in accountability check")
            }

            if !prep.yourOpenPromises.isEmpty {
                Text("What YOU promised before this meeting")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                ForEach(prep.yourOpenPromises) { item in
                    CommitmentRowView(
                        item: item,
                        showOwner: false,
                        availableReminderLists: model.reminders.availableLists,
                        remindersConnected: RemindersSyncService.hasAccess,
                        onToggle: { done in model.toggleCommitment(item, done: done) },
                        onOpenMeeting: { onOpenMeeting(item.meetingFolder, item.actionItem.t) },
                        onSendToReminders: { listID in model.sendActionItemToReminders(item.actionItem, in: item.meetingFolder, listID: listID) },
                        onUnlinkReminder: { deleteInReminders in model.unlinkActionItemFromReminders(item.actionItem, in: item.meetingFolder, deleteInReminders: deleteInReminders) }
                    )
                }
            }

            if !prep.theirOpenPromises.isEmpty {
                Text("What THEY promised you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fg2)
                    .padding(.top, prep.yourOpenPromises.isEmpty ? 0 : 4)
                ForEach(prep.theirOpenPromises) { item in
                    CommitmentRowView(
                        item: item,
                        showOwner: true,
                        availableReminderLists: model.reminders.availableLists,
                        remindersConnected: RemindersSyncService.hasAccess,
                        onToggle: { done in model.toggleCommitment(item, done: done) },
                        onOpenMeeting: { onOpenMeeting(item.meetingFolder, item.actionItem.t) },
                        onSendToReminders: { listID in model.sendActionItemToReminders(item.actionItem, in: item.meetingFolder, listID: listID) },
                        onUnlinkReminder: { deleteInReminders in model.unlinkActionItemFromReminders(item.actionItem, in: item.meetingFolder, deleteInReminders: deleteInReminders) }
                    )
                }
            }
        }
        .padding(14)
        .background(Theme.mark.opacity(0.42), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.accent.opacity(0.22)))
    }

    private func lastMeetingRecapCard(_ last: MeetingPrepBrief.PriorMeetingRecap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Last time (\(last.date.formatted(.dateTime.month(.abbreviated).day())))")
                Spacer()
                Button("Open \(last.title) ↗") {
                    onOpenMeeting(last.folder, nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(last.decisions) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text(d.text)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.fg)
                    }
                }
                ForEach(last.takeaways) { pt in
                    Text("• \(pt.text)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.fg2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        }
    }
}

// MARK: - Two-Way Commitments Radar Board

struct CommitmentsRadarDetailView: View {
    enum RecencyWindow: String, CaseIterable, Identifiable {
        case week = "7d"
        case month = "30d"
        case all = "All"
        var id: String { rawValue }
        var maxAgeDays: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    @Environment(AppModel.self) private var model
    let onOpenMeeting: (MeetingFolder, Double?) -> Void
    @State private var showCompleted = false
    @State private var window: RecencyWindow = .month
    @State private var showOthers = false
    @State private var remindersFilter: String? = nil
    @State private var syncingReminders = false

    private var availableListFilters: [String] {
        var names: [String] = []
        for item in model.hub.commitments {
            if let name = item.actionItem.reminderListName, !name.isEmpty,
               !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }
        return names.sorted()
    }

    private var visibleItems: [CommitmentItem] {
        model.hub.commitments.filter { item in
            if !showCompleted && item.actionItem.done { return false }
            if let cap = window.maxAgeDays, item.ageDays > cap { return false }
            if let remindersFilter {
                guard let name = item.actionItem.reminderListName,
                      name.caseInsensitiveCompare(remindersFilter) == .orderedSame else {
                    return false
                }
            }
            return true
        }
    }

    private var mine: [CommitmentItem] {
        visibleItems.filter { $0.relevance == .mine }
    }

    private var waitingOnOthers: [CommitmentItem] {
        visibleItems.filter { $0.relevance == .relatedToMe }
    }

    private var otherTeamItems: [CommitmentItem] {
        visibleItems.filter { $0.relevance == .others }
    }

    var body: some View {
        ResponsiveDocumentScroll(maxWidth: 660, topPadding: 24, bottomPadding: 48) { _ in
            VStack(alignment: .leading, spacing: 22) {
                WrappingFlowLayout(spacing: 12, lineSpacing: 8) {
                    Text("Commitments")
                        .font(Fonts.title)
                        .foregroundStyle(Theme.fg)

                    HStack(spacing: 10) {
                        Picker("Range", selection: $window) {
                            ForEach(RecencyWindow.allCases) { w in
                                Text(w.rawValue).tag(w)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 132)
                        .help("Filter commitments by meeting recency")

                        Toggle("Show completed", isOn: $showCompleted)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                remindersBar

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "For you (\(mine.count))")
                    if mine.isEmpty {
                        Text("Nothing open on your plate in this range.")
                            .font(.callout)
                            .foregroundStyle(Theme.fg2)
                    } else {
                        ForEach(mine) { item in
                            radarRow(item, showOwner: false)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Waiting on others (\(waitingOnOthers.count))")
                        .help("Tasks others own that directly involve or unblock you")
                    if waitingOnOthers.isEmpty {
                        Text("No open items waiting on others right now.")
                            .font(.callout)
                            .foregroundStyle(Theme.fg2)
                    } else {
                        ForEach(waitingOnOthers) { item in
                            radarRow(item, showOwner: true)
                        }
                    }
                }

                if !otherTeamItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.snappy(duration: 0.16)) { showOthers.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .rotationEffect(.degrees(showOthers ? 90 : 0))
                                SectionHeader(title: "Other team items (\(otherTeamItems.count))")
                            }
                            .foregroundStyle(Theme.fg2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show or hide team tasks that do not involve you")

                        if showOthers {
                            ForEach(otherTeamItems) { item in
                                radarRow(item, showOwner: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func radarRow(_ item: CommitmentItem, showOwner: Bool) -> some View {
        CommitmentRowView(
            item: item,
            showOwner: showOwner,
            availableReminderLists: model.reminders.availableLists,
            remindersConnected: RemindersSyncService.hasAccess,
            onToggle: { done in model.toggleCommitment(item, done: done) },
            onOpenMeeting: { onOpenMeeting(item.meetingFolder, item.actionItem.t) },
            onDismiss: { model.dismissCommitment(item) },
            onSendToReminders: { listID in model.sendActionItemToReminders(item.actionItem, in: item.meetingFolder, listID: listID) },
            onUnlinkReminder: { deleteInReminders in model.unlinkActionItemFromReminders(item.actionItem, in: item.meetingFolder, deleteInReminders: deleteInReminders) }
        )
    }

    @ViewBuilder
    private var remindersBar: some View {
        let filters = availableListFilters
        HStack(spacing: 8) {
            if !filters.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        filterPill(title: "All lists", active: remindersFilter == nil) {
                            remindersFilter = nil
                        }
                        ForEach(filters, id: \.self) { name in
                            filterPill(title: name, active: remindersFilter == name) {
                                remindersFilter = (remindersFilter == name) ? nil : name
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if RemindersSyncService.hasAccess {
                Button {
                    syncingReminders = true
                    Task {
                        _ = await model.syncOpenCommitmentsToReminders()
                        model.pullRemindersChanges()
                        syncingReminders = false
                    }
                } label: {
                    Label(syncingReminders ? "Syncing…" : "Sync to Reminders", systemImage: "checklist")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(syncingReminders)
            } else {
                Button {
                    Task {
                        if await model.reminders.requestAccess() {
                            model.reminders.start()
                        } else {
                            model.openSettings(pane: .reminders)
                        }
                    }
                } label: {
                    Label("Connect Apple Reminders", systemImage: "checklist")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func filterPill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.accent : Theme.fg2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(active ? Theme.mark : Theme.bg, in: Capsule())
                .overlay(Capsule().stroke(active ? Theme.accent.opacity(0.3) : Theme.line))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Google / iCal `.ics` Subscription Modal

struct AddICSFeedSheet: View {
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Google or iCal Calendar (.ics)")
                .font(.headline)

            Text("In Google Calendar on the web, open **Settings → Settings for my calendars → [Your Calendar] → Integrate calendar**, copy the **Secret address in iCal format**, and paste it below. ReMeet syncs it automatically in the background—no account login or cloud server needed.")
                .font(.callout)
                .foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Label (optional, e.g. Work Google Calendar)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("https://calendar.google.com/calendar/ical/.../basic.ics", text: $urlString)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect & Sync") {
                    onAdd(name, urlString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
