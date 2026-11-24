import AppKit
import ReMeetKit
import SwiftUI

enum PeopleFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case voice = "Voice"
    case upcoming = "Soon"
    case promises = "Tasks"

    var id: String { rawValue }
}

/// Sidebar list for the People tab: filter pills, `+` Add Person button, and avatar rows.
struct PeopleSidebarContent: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedPersonID: String?
    let search: String
    @State private var filter: PeopleFilter = .all
    @State private var addingPerson = false

    private var filteredPeople: [PersonSummary] {
        var list = model.hub.people
        switch filter {
        case .all: break
        case .voice: list = list.filter(\.hasVoiceprint)
        case .upcoming: list = list.filter { $0.nextMeeting != nil }
        case .promises: list = list.filter { $0.openCommitmentsCount > 0 }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.profile.name.localizedCaseInsensitiveContains(q)
                    || ($0.profile.organization?.localizedCaseInsensitiveContains(q) == true)
                    || ($0.profile.role?.localizedCaseInsensitiveContains(q) == true)
                    || ($0.profile.email?.localizedCaseInsensitiveContains(q) == true)
                    || $0.profile.notes.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var body: some View {
        List {
            Section {
                filterRow
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 6, trailing: 10))
                    .listRowBackground(Color.clear)

                ForEach(filteredPeople) { person in
                    let isSelected = selectedPersonID == person.id
                    PersonSidebarRow(person: person, isSelected: isSelected)
                        .sidebarRow(selected: isSelected) {
                            selectedPersonID = person.id
                        }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("People (\(filteredPeople.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fg3)
                        .textCase(nil)
                    Spacer()
                    Button {
                        addingPerson = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.fg2)
                            .frame(width: 20, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add a person")
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if filteredPeople.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Theme.fg3)
                    Text(search.isEmpty ? "No people yet" : "No matching people")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                    Text(search.isEmpty
                         ? "Name a speaker in a recording or connect your calendar to build profiles automatically."
                         : "Try another name, company, or role.")
                        .font(.caption)
                        .foregroundStyle(Theme.fg3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }
            }
        }
        .sheet(isPresented: $addingPerson) {
            PersonEditorSheet(existing: nil) { name, email, role, org, notes in
                if let created = model.hub.createPerson(name: name, email: email, role: role,
                                                        organization: org, notes: notes,
                                                        recorderName: AppModel.recorderName) {
                    selectedPersonID = created.id
                }
            }
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(PeopleFilter.allCases) { item in
                    let active = filter == item
                    Button {
                        filter = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Theme.accent : Theme.fg2)
                            .padding(.horizontal, 7.5)
                            .padding(.vertical, 3.5)
                            .background(active ? Theme.mark : Theme.surface.opacity(0.6), in: Capsule())
                            .overlay(Capsule().stroke(active ? Theme.accent.opacity(0.3) : Theme.line))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PersonSidebarRow: View {
    let person: PersonSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            PersonAvatarView(profile: person.profile, size: 30, hasVoiceprint: person.hasVoiceprint)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.fg)
                    .lineLimit(1)

                Text(secondaryLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if person.openCommitmentsCount > 0 {
                Text("\(person.openCommitmentsCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Theme.mark, in: Capsule())
                    .help("\(person.openCommitmentsCount) open commitment\(person.openCommitmentsCount == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 2)
    }

    private var secondaryLine: String {
        if let sub = person.profile.subtitle, !sub.isEmpty {
            return sub
        }
        if person.meetingsCount > 0 {
            return "\(person.meetingsCount) meeting\(person.meetingsCount == 1 ? "" : "s")"
        }
        if let next = person.nextMeeting {
            return "Next: \(next.start.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "Profile"
    }
}

// MARK: - Person Detail View ("Walk in already knowing")

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let person: PersonSummary
    let onOpenMeeting: (MeetingFolder, Double?) -> Void

    @State private var editingProfile = false
    @State private var mergingPerson = false
    @State private var confirmingDelete = false
    @State private var notesDraft: String = ""
    @State private var notesSaved = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        ResponsiveDocumentScroll(maxWidth: 660, topPadding: 24, bottomPadding: 48) { _ in
            VStack(alignment: .leading, spacing: 22) {
                heroHeader
                if let next = person.nextMeeting {
                    upcomingBanner(next)
                }
                statsStrip
                contextNotesCard
                commitmentsSection
                conversationsSection
            }
        }
        .onAppear { notesDraft = person.profile.notes }
        .onChange(of: person.id) { _, _ in
            notesDraft = person.profile.notes
            notesSaved = false
        }
        .sheet(isPresented: $editingProfile) {
            PersonEditorSheet(existing: person.profile) { name, email, role, org, notes in
                model.hub.updatePerson(id: person.id, name: name, email: email, role: role,
                                       organization: org, notes: notes, recorderName: AppModel.recorderName)
                notesDraft = notes
            }
        }
        .sheet(isPresented: $mergingPerson) {
            PersonMergeSheet(source: person, candidates: model.hub.people.filter { $0.id != person.id }) { targetID in
                model.hub.mergePeople(sourceID: person.id, into: targetID, recorderName: AppModel.recorderName)
                model.selectedPersonID = targetID
            }
        }
        .confirmationDialog("Remove \(person.profile.name) from People?",
                            isPresented: $confirmingDelete) {
            Button("Remove Person & Voiceprint", role: .destructive) {
                model.hub.deletePerson(person, removeVoiceprint: true, recorderName: AppModel.recorderName)
            }
        } message: {
            Text("Their profile and saved voice sample are removed. Your recorded meetings and transcripts stay intact.")
        }
    }

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            PersonAvatarView(profile: person.profile, size: 54, hasVoiceprint: person.hasVoiceprint)

            VStack(alignment: .leading, spacing: 6) {
                Text(person.profile.name)
                    .font(Fonts.title)
                    .foregroundStyle(Theme.fg)

                let metaParts = [person.profile.role, person.profile.organization, person.profile.email]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " · "))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if person.hasVoiceprint {
                        Label("Voiceprint · \(TimeFormat.duration(person.voiceSampleSeconds))",
                              systemImage: "waveform")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Theme.mark, in: Capsule())
                            .help("Recognized automatically in future recordings")
                    } else {
                        Label("No voiceprint",
                              systemImage: "waveform.badge.plus")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Theme.bg, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line))
                            .help("Name them once in any recording so ReMeet recognizes their voice next time")
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("Edit") { editingProfile = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Menu {
                    if model.hub.people.count > 1 {
                        Button("Merge into another person…") { mergingPerson = true }
                    }
                    if person.hasVoiceprint {
                        Button("Reset saved voiceprint") {
                            model.hub.forgetVoiceprint(for: person, recorderName: AppModel.recorderName)
                        }
                    }
                    Divider()
                    Button("Remove person…", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.fg2)
                        .hitTarget(4)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func upcomingBanner(_ event: CalendarMeeting) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next together: \(event.title)")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("\(event.start.formatted(date: .abbreviated, time: .shortened))\(event.callService.map { " · \($0)" } ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg2)
            }
            Spacer()
            Button("Walk-in brief") {
                model.openSchedule(selecting: event.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if event.joinURL != nil {
                AccentCapsuleButton(title: "Join & Record", systemImage: "video.fill", small: true) {
                    model.joinAndRecord(event)
                }
            }
        }
        .padding(12)
        .background(Theme.mark.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.25)))
    }

    private var statsStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 10)], spacing: 10) {
            statCard(title: "Meetings", value: "\(person.meetingsCount)",
                     sub: person.lastMetDate.map { "Last \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? nil)
            statCard(title: "Spoken time", value: person.totalTalkSeconds > 0 ? TimeFormat.duration(person.totalTalkSeconds) : "0m",
                     sub: nil)
            statCard(title: "Waiting on them", value: "\(person.theirOpenCommitments.count)",
                     sub: nil)
            statCard(title: "For you", value: "\(person.yourOpenCommitments.count)",
                     sub: nil)
        }
    }

    private func statCard(title: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.fg3)
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.fg)
            if let sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.line))
    }

    private var contextNotesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Context & background")
                    .help("Who they are, what they care about, projects and context — automatically passed into summaries when they speak.")
                Spacer()
                if notesDraft != person.profile.notes {
                    Button("Save note") { commitNotes() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else if notesSaved {
                    Text("Saved")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            TextEditor(text: $notesDraft)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.fg)
                .scrollContentBackground(.hidden)
                .focused($notesFocused)
                .frame(minHeight: 68, maxHeight: 130)
                .padding(8)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(notesFocused ? Theme.accent.opacity(0.5) : Theme.line))
                .onChange(of: notesFocused) { _, focused in
                    if !focused, notesDraft != person.profile.notes { commitNotes() }
                }
        }
    }

    private func commitNotes() {
        model.hub.updatePerson(id: person.id,
                               name: person.profile.name,
                               email: person.profile.email,
                               role: person.profile.role,
                               organization: person.profile.organization,
                               notes: notesDraft,
                               recorderName: AppModel.recorderName)
        notesSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            notesSaved = false
        }
    }

    @ViewBuilder private var commitmentsSection: some View {
        let hasAny = !person.theirOpenCommitments.isEmpty || !person.yourOpenCommitments.isEmpty
        if hasAny {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Open commitments")

                if !person.theirOpenCommitments.isEmpty {
                    Text("Waiting on \(person.profile.name.split(separator: " ").first.map(String.init) ?? person.profile.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                    ForEach(person.theirOpenCommitments) { item in
                        CommitmentRowView(item: item, showOwner: false) { done in
                            model.toggleCommitment(item, done: done)
                        } onOpenMeeting: {
                            onOpenMeeting(item.meetingFolder, item.actionItem.t)
                        }
                    }
                }

                if !person.yourOpenCommitments.isEmpty {
                    Text("You promised in calls together")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                        .padding(.top, person.theirOpenCommitments.isEmpty ? 0 : 4)
                    ForEach(person.yourOpenCommitments) { item in
                        CommitmentRowView(item: item, showOwner: false) { done in
                            model.toggleCommitment(item, done: done)
                        } onOpenMeeting: {
                            onOpenMeeting(item.meetingFolder, item.actionItem.t)
                        }
                    }
                }
            }
        }
    }

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Conversations (\(person.conversations.count))")
            if person.conversations.isEmpty {
                Text("No recorded conversations yet. Once \(person.profile.name) is named in a recording or joins a linked calendar call, every conversation appears here.")
                    .font(.callout)
                    .foregroundStyle(Theme.fg2)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            } else {
                ForEach(person.conversations) { conv in
                    Button {
                        onOpenMeeting(conv.folder, nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(conv.title)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.fg)
                                Spacer()
                                Text(conv.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.fg2)
                                if conv.personTalkSeconds > 0 {
                                    Text("· Spoke \(TimeFormat.duration(conv.personTalkSeconds))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.accent)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.fg3)
                            }

                            if !conv.decisions.isEmpty {
                                ForEach(conv.decisions.prefix(2)) { dec in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.accent)
                                        Text(dec.text)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.fg)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                            } else if !conv.summaryHighlights.isEmpty {
                                ForEach(conv.summaryHighlights.prefix(2)) { pt in
                                    Text("• \(pt.text)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.fg2)
                                        .multilineTextAlignment(.leading)
                                }
                            }

                            if let quote = conv.sampleQuote, !quote.isEmpty {
                                Text("\u{201C}\(quote)\u{201D}")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.fg3)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bg.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Modals

struct PersonEditorSheet: View {
    let existing: PersonProfile?
    let onSave: (String, String?, String?, String?, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var role = ""
    @State private var organization = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Person" : "Edit Person")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").font(.subheadline.weight(.medium)).foregroundStyle(Theme.fg2)
                    TextField("e.g. Priya Patel", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Role").font(.subheadline.weight(.medium)).foregroundStyle(Theme.fg2)
                    TextField("e.g. Product Lead", text: $role)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Organization").font(.subheadline.weight(.medium)).foregroundStyle(Theme.fg2)
                    TextField("e.g. Acme", text: $organization)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Email").font(.subheadline.weight(.medium)).foregroundStyle(Theme.fg2)
                    TextField("e.g. priya@acme.io", text: $email)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Context note").font(.subheadline.weight(.semibold))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                Text("Included as background context in summaries when \(name.isEmpty ? "this person" : name) speaks.")
                    .font(.caption)
                    .foregroundStyle(Theme.fg2)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") {
                    onSave(name, email, role, organization, notes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                .disabled(SpeakerMemory.isPlaceholder(name))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let existing {
                name = existing.name
                email = existing.email ?? ""
                role = existing.role ?? ""
                organization = existing.organization ?? ""
                notes = existing.notes
            }
        }
    }
}

private struct PersonMergeSheet: View {
    let source: PersonSummary
    let candidates: [PersonSummary]
    let onMerge: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \u{201C}\(source.profile.name)\u{201D}")
                .font(.headline)
            Text("Combines \(source.profile.name)'s conversations, aliases, context notes, and voiceprint into the person you choose.")
                .font(.callout)
                .foregroundStyle(Theme.fg2)
            Picker("Merge into", selection: $targetID) {
                ForEach(candidates) { c in
                    Text(c.profile.name).tag(c.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Merge") {
                    if !targetID.isEmpty { onMerge(targetID) }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
                .disabled(targetID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { targetID = candidates.first?.id ?? "" }
    }
}
