import AppKit
import ReMeetKit
import SwiftUI

/// Integrated Calendar & Smart Week Focus view ("This Week" / "Upcoming Week" + Week/Month calendar + Focus Action Items).
struct ScheduleWeekOverviewView: View {
    enum CalendarDisplayMode: String, CaseIterable, Identifiable {
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    let onSelectEvent: (String) -> Void
    let onOpenMeeting: (MeetingFolder, Double?) -> Void

    @State private var mode: CalendarDisplayMode = .week
    @State private var weekOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var selectedDay: Date?
    @State private var showOtherOpenItems = false
    @State private var showingAddICS = false
    @State private var syncingWeek = false
    @State private var weekSyncNotice: String?

    private var calendar: Calendar {
        ScheduleWeekFocus.mondayFirstCalendar()
    }

    private var focusWindow: ScheduleWeekFocus.FocusWindow {
        ScheduleWeekFocus.window(weekOffset: weekOffset, now: Date(), events: model.calendar.events)
    }

    private var weekPlan: WeekFocusPlan {
        let snapshots = model.hub.snapshotsByID.values.sorted { $0.meta.startTime > $1.meta.startTime }
        return WeekFocusPlan.build(
            window: focusWindow,
            events: model.calendar.events,
            snapshots: snapshots,
            people: model.hub.people,
            recorderName: AppModel.recorderName
        )
    }

    private var displayedMonthAnchor: Date {
        let base = focusWindow.weekStart
        return calendar.date(byAdding: .month, value: monthOffset, to: base) ?? base
    }

    private var allOnlineEvents: [CalendarMeeting] {
        model.calendar.events
            .filter { MeetingReminder.hasOnlineMeetingPlatform($0) }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        let plan = weekPlan
        ResponsiveDocumentScroll(maxWidth: 780, topPadding: 24, bottomPadding: 48) { availableWidth in
            VStack(alignment: .leading, spacing: 22) {
                headerRow(plan: plan)

                if !CalendarWatcher.hasAccess && model.calendar.icsFeeds.isEmpty && model.calendar.source == nil {
                    connectCalendarCard
                }

                if mode == .week {
                    weekGridSection(plan: plan, availableWidth: availableWidth)
                } else {
                    monthGridSection(plan: plan)
                }

                meetingsListSection(plan: plan)
                focusActionItemsSection(plan: plan)
            }
        }
        .sheet(isPresented: $showingAddICS) {
            AddICSFeedSheet { name, url in
                _ = model.calendar.addICSFeed(name: name, urlString: url)
                model.calendarRemindersChanged()
            }
        }
    }

    // MARK: - Header

    private func headerRow(plan: WeekFocusPlan) -> some View {
        WrappingFlowLayout(spacing: 12, lineSpacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .week ? plan.window.title : displayedMonthAnchor.formatted(.dateTime.month(.wide).year()))
                    .font(Fonts.title)
                    .foregroundStyle(Theme.fg)

                let meetingCount = mode == .week ? plan.remainingEvents.count : events(inMonthOf: displayedMonthAnchor).count
                let countLabel = mode == .week && plan.window.isCurrentWeek ? "left this week" : "scheduled"
                let taskCount = plan.totalFocusActionItems
                Text("\(plan.window.dateRangeLabel) · \(meetingCount) meeting\(meetingCount == 1 ? "" : "s") \(countLabel)\(taskCount > 0 ? " · \(taskCount) focus task\(taskCount == 1 ? "" : "s")" : "")")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fg2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Button {
                        stepPeriod(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(mode == .week ? "Previous week" : "Previous month")

                    Button(focusButtonLabel) {
                        weekOffset = 0
                        monthOffset = 0
                        selectedDay = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mode == .week ? weekOffset == 0 : monthOffset == 0)

                    Button {
                        stepPeriod(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(mode == .week ? "Next week" : "Next month")
                }

                Picker("View", selection: $mode) {
                    ForEach(CalendarDisplayMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 118)
            }
        }
    }

    private var focusButtonLabel: String {
        if mode == .week {
            return ScheduleWeekFocus.defaultFocus(now: Date(), events: model.calendar.events).isUpcomingWeek ? "Next Week" : "This Week"
        }
        return "Today"
    }

    private func stepPeriod(_ delta: Int) {
        selectedDay = nil
        if mode == .week {
            weekOffset += delta
        } else {
            monthOffset += delta
        }
    }

    private var connectCalendarCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect your Apple or Google Calendar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("See your upcoming week inside ReMeet, get Walk-In Prep Briefs, and highlight priority action items before every call.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg2)
            }
            Spacer()
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
            Button("Add .ics…") { showingAddICS = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
    }

    // MARK: - Week Calendar Grid

    @ViewBuilder
    private func weekGridSection(plan: WeekFocusPlan, availableWidth: CGFloat) -> some View {
        let days = ScheduleWeekFocus.weekDays(startingAt: plan.window.weekStart, calendar: calendar)
        if availableWidth >= 560 {
            HStack(alignment: .top, spacing: 6) {
                ForEach(days, id: \.self) { day in
                    weekDayColumn(day: day, plan: plan)
                }
            }
            .padding(10)
            .background(Theme.bg.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)], spacing: 8) {
                ForEach(days, id: \.self) { day in
                    weekDayColumn(day: day, plan: plan)
                }
            }
        }
    }

    private func weekDayColumn(day: Date, plan: WeekFocusPlan) -> some View {
        let isToday = calendar.isDateInToday(day)
        let isPastDay = calendar.startOfDay(for: day) < calendar.startOfDay(for: Date())
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let dayEvents = events(on: day, in: plan.weekEvents)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isSelected {
                    selectedDay = nil
                } else {
                    selectedDay = day
                }
            } label: {
                HStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isToday ? Theme.accent : Theme.fg3)
                    Spacer(minLength: 2)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 12, weight: isToday || isSelected ? .bold : .semibold).monospacedDigit())
                        .foregroundStyle(isToday ? .white : (isSelected ? Theme.accent : Theme.fg))
                        .frame(width: 22, height: 22)
                        .background(isToday ? Theme.accentFill : (isSelected ? Theme.mark : .clear), in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if dayEvents.isEmpty {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg3.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(dayEvents) { event in
                        let hasTasks = plan.eventIDsWithActionItems.contains(event.id)
                        let recorded = isRecorded(event)
                        Button {
                            onSelectEvent(event.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 3) {
                                    Text(event.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(event.end < Date() ? Theme.fg3 : Theme.accent)
                                    Spacer(minLength: 2)
                                    if hasTasks {
                                        Circle()
                                            .fill(Theme.accent)
                                            .frame(width: 5, height: 5)
                                            .help("Has open action items")
                                    }
                                    if recorded {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                                Text(event.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(event.end < Date() ? Theme.fg2 : Theme.fg)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(hasTasks ? Theme.mark.opacity(0.6) : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(hasTasks ? Theme.accent.opacity(0.28) : Theme.line)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .frame(minHeight: 54, alignment: .top)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            isSelected ? Theme.mark.opacity(0.45) : (isToday ? Theme.mark.opacity(0.22) : Theme.surface.opacity(isPastDay ? 0.5 : 0.85)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Theme.accent.opacity(0.5) : (isToday ? Theme.accent.opacity(0.25) : Theme.line.opacity(0.8)))
        )
        .opacity(isPastDay && !isSelected ? 0.72 : 1)
    }

    // MARK: - Month Calendar Grid

    private func monthGridSection(plan: WeekFocusPlan) -> some View {
        let gridDays = ScheduleWeekFocus.monthGridDays(containing: displayedMonthAnchor, calendar: calendar)
        let targetMonth = calendar.component(.month, from: displayedMonthAnchor)
        let weekdayHeaders = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(weekdayHeaders, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 2)
                }

                ForEach(gridDays, id: \.self) { day in
                    let inMonth = calendar.component(.month, from: day) == targetMonth
                    let isToday = calendar.isDateInToday(day)
                    let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                    let dayEvents = events(on: day, in: allOnlineEvents)

                    Button {
                        if isSelected {
                            selectedDay = nil
                        } else {
                            selectedDay = day
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(day.formatted(.dateTime.day()))
                                    .font(.system(size: 11, weight: isToday || isSelected ? .bold : .medium).monospacedDigit())
                                    .foregroundStyle(isToday ? .white : (inMonth ? Theme.fg : Theme.fg3))
                                    .frame(width: 20, height: 20)
                                    .background(isToday ? Theme.accentFill : .clear, in: Circle())
                                Spacer()
                                if dayEvents.count > 2 {
                                    Text("+\(dayEvents.count - 2)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.fg3)
                                }
                            }
                            ForEach(dayEvents.prefix(2)) { ev in
                                Text(ev.title)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(plan.eventIDsWithActionItems.contains(ev.id) ? Theme.accent : Theme.fg2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.mark.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                        .background(
                            isSelected ? Theme.mark.opacity(0.55) : (inMonth ? Theme.surface : Theme.bg.opacity(0.4)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Theme.accent : (isToday ? Theme.accent.opacity(0.45) : Theme.line.opacity(0.8)))
                        )
                        .opacity(inMonth ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Theme.bg.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }

    // MARK: - Meetings List

    @ViewBuilder
    private func meetingsListSection(plan: WeekFocusPlan) -> some View {
        let shownEvents: [CalendarMeeting] = {
            if let day = selectedDay {
                return events(on: day, in: allOnlineEvents)
            }
            if mode == .month {
                return events(inMonthOf: displayedMonthAnchor)
            }
            return plan.remainingEvents.isEmpty ? plan.weekEvents : plan.remainingEvents
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let day = selectedDay {
                    SectionHeader(title: "Meetings on \(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) (\(shownEvents.count))")
                    Button("Show all") { selectedDay = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    let label = mode == .week
                        ? (plan.window.isCurrentWeek && !plan.remainingEvents.isEmpty ? "Remaining this week" : "Meetings in \(plan.window.title.lowercased())")
                        : "Meetings in \(displayedMonthAnchor.formatted(.dateTime.month(.wide)))"
                    SectionHeader(title: "\(label) (\(shownEvents.count))")
                }
                Spacer()
            }

            if shownEvents.isEmpty {
                Text(selectedDay != nil ? "No online meetings scheduled on this day." : "No online meetings scheduled in this window.")
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
            } else {
                ForEach(shownEvents) { event in
                    meetingRowCard(event, hasTasks: plan.eventIDsWithActionItems.contains(event.id))
                }
            }
        }
    }

    private func meetingRowCard(_ event: CalendarMeeting, hasTasks: Bool) -> some View {
        let recorded = isRecorded(event)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .lineLimit(1)
                    if recorded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .help("Recorded in ReMeet")
                    }
                    if hasTasks {
                        Text("Focus tasks")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Theme.mark, in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text("\(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                    if let service = event.callService {
                        Text("·").foregroundStyle(Theme.fg3)
                        Text(service)
                    }
                    if !event.attendees.isEmpty {
                        let count = event.attendees.filter { $0.status != .declined }.count
                        if count > 0 {
                            Text("·").foregroundStyle(Theme.fg3)
                            Text("\(count) invitee\(count == 1 ? "" : "s")")
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.fg2)
            }

            Spacer(minLength: 8)

            Button("Prep Brief") {
                onSelectEvent(event.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if event.joinURL != nil, !model.recorder.isRecording {
                AccentCapsuleButton(title: "Join & Record", systemImage: "video.fill", small: true) {
                    model.joinAndRecord(event)
                }
            }
        }
        .padding(12)
        .background(Theme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(hasTasks ? Theme.accent.opacity(0.28) : Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture {
            onSelectEvent(event.id)
        }
    }

    // MARK: - Action Items to Focus On

    @ViewBuilder
    private func focusActionItemsSection(plan: WeekFocusPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    SectionHeader(title: "Action items to focus on")
                }
                Spacer()
                if let weekSyncNotice {
                    Text(weekSyncNotice)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                let weekItems: [CommitmentItem] = {
                    let grouped = plan.actionGroups.flatMap { $0.yourItems + $0.theirItems }
                    return grouped.isEmpty ? plan.otherRecentMine : grouped
                }()
                Button {
                    syncWeekItems(weekItems, label: plan.window.title)
                } label: {
                    Label(syncingWeek ? "Syncing…" : "Sync \(plan.window.title) to Reminders", systemImage: "checklist")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(syncingWeek || weekItems.isEmpty)
            }

            if plan.actionGroups.isEmpty && plan.otherRecentMine.isEmpty {
                Text("No open action items queued for your upcoming meetings.")
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
            } else {
                ForEach(plan.actionGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                onSelectEvent(group.event.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Text("Before \(group.event.title)")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.fg)
                                    Text("· \(group.event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.fg2)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                syncWeekItems(group.yourItems + group.theirItems, label: group.event.title)
                            } label: {
                                Label("Sync", systemImage: "checklist")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.accent.opacity(0.25)))
                            }
                            .buttonStyle(.plain)
                            .disabled(syncingWeek)
                            .help("Sync action items for \(group.event.title) to Apple Reminders")
                        }

                        ForEach(group.yourItems) { item in
                            commitmentRow(item, showOwner: false)
                        }
                        ForEach(group.theirItems) { item in
                            commitmentRow(item, showOwner: true)
                        }
                    }
                    .padding(12)
                    .background(Theme.mark.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.22)))
                }

                if !plan.otherRecentMine.isEmpty {
                    let expandDefault = plan.actionGroups.isEmpty
                    if expandDefault {
                        Text("Your open items")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.fg2)
                        ForEach(plan.otherRecentMine.prefix(12)) { item in
                            commitmentRow(item, showOwner: false)
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.16)) { showOtherOpenItems.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showOtherOpenItems ? 90 : 0))
                                Text("Other open items (\(plan.otherRecentMine.count))")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Theme.fg2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showOtherOpenItems {
                            ForEach(plan.otherRecentMine.prefix(12)) { item in
                                commitmentRow(item, showOwner: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func syncWeekItems(_ items: [CommitmentItem], label: String) {
        guard !items.isEmpty else { return }
        syncingWeek = true
        Task {
            let count = await model.syncCommitmentsToReminders(items)
            syncingWeek = false
            weekSyncNotice = count == 0 ? "Up to date" : "Synced \(count) item\(count == 1 ? "" : "s")"
            try? await Task.sleep(for: .seconds(3))
            weekSyncNotice = nil
        }
    }

    private func commitmentRow(_ item: CommitmentItem, showOwner: Bool) -> some View {
        CommitmentRowView(
            item: item,
            showOwner: showOwner,
            availableReminderLists: model.reminders.availableLists,
            remindersConnected: RemindersSyncService.hasAccess,
            onToggle: { done in model.toggleCommitment(item, done: done) },
            onOpenMeeting: { onOpenMeeting(item.meetingFolder, item.actionItem.t) },
            onDismiss: { model.dismissCommitment(item) },
            onSendToReminders: { listID in
                model.sendActionItemToReminders(item.actionItem, in: item.meetingFolder, listID: listID)
            },
            onUnlinkReminder: { deleteInReminders in
                model.unlinkActionItemFromReminders(item.actionItem, in: item.meetingFolder, deleteInReminders: deleteInReminders)
            }
        )
    }

    // MARK: - Helpers

    private func events(on day: Date, in source: [CalendarMeeting]) -> [CalendarMeeting] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return source.filter { $0.start < dayEnd && $0.end > dayStart }
    }

    private func events(inMonthOf anchor: Date) -> [CalendarMeeting] {
        let comps = calendar.dateComponents([.year, .month], from: anchor)
        guard let monthStart = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: range.count, to: monthStart) else {
            return []
        }
        return allOnlineEvents.filter { $0.start < monthEnd && $0.end > monthStart }
    }

    private func isRecorded(_ event: CalendarMeeting) -> Bool {
        model.library.items.contains { item in
            if item.meta.calendarEventID == event.id { return true }
            return abs(item.meta.startTime.timeIntervalSince(event.start)) <= 20 * 60
                && MeetingReminder.seriesKey(for: item.meta.title) == event.seriesKey
        }
    }
}
