import AppKit
import Observation
import ReMeetKit
import SwiftUI

/// Sequences playback through a meeting's Key Moments back-to-back ("Listen to 5 highlights in 1m 04s").
@MainActor
@Observable
final class HighlightReelController {
    private(set) var activeMomentID: String?
    private(set) var currentStopIndex: Int = 0
    private(set) var totalStops: Int = 0
    private var task: Task<Void, Never>?

    var isPlaying: Bool { activeMomentID != nil }

    func toggle(moments: [KeyMoment], player: PlayerModel) {
        if isPlaying {
            stop(player: player)
        } else {
            start(moments: moments, player: player)
        }
    }

    func playSingle(_ moment: KeyMoment, player: PlayerModel) {
        if activeMomentID == moment.id, totalStops == 1 {
            stop(player: player)
            return
        }
        runStops([HighlightReelPlan.Stop(momentID: moment.id, title: moment.title,
                                         startTime: moment.startTime, endTime: moment.endTime)],
                 player: player)
    }

    func start(moments: [KeyMoment], player: PlayerModel) {
        let plan = HighlightReelPlan.build(from: moments)
        guard !plan.stops.isEmpty else { return }
        runStops(plan.stops, player: player)
    }

    func stop(player: PlayerModel? = nil) {
        task?.cancel()
        task = nil
        activeMomentID = nil
        currentStopIndex = 0
        totalStops = 0
        player?.pause()
    }

    private func runStops(_ stops: [HighlightReelPlan.Stop], player: PlayerModel) {
        task?.cancel()
        totalStops = stops.count
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for (idx, item) in stops.enumerated() {
                guard !Task.isCancelled else { break }
                self.currentStopIndex = idx + 1
                self.activeMomentID = item.momentID
                player.play(from: item.startTime)
                try? await Task.sleep(for: .seconds(item.duration))
                guard !Task.isCancelled else { break }
                if idx + 1 < stops.count {
                    player.pause()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            guard !Task.isCancelled else { return }
            player.pause()
            self.activeMomentID = nil
            self.currentStopIndex = 0
            self.totalStops = 0
        }
    }
}

// MARK: - Conversation Pulse Ribbon (Talk-Time Dynamics + Moment Pins)

struct ConversationPulseBar: View {
    let pulse: ConversationPulse
    let moments: [KeyMoment]
    let hasAudio: Bool
    let onScrub: (Double) -> Void
    let onSelectSpeaker: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !pulse.shares.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                WrappingFlowLayout(spacing: 6, lineSpacing: 4) {
                    Label("Conversation pulse", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(1)
                    if !pulse.paceLabel.isEmpty {
                        Text("·").foregroundStyle(Theme.fg3)
                        Text(pulse.paceLabel)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg3)
                            .lineLimit(1)
                    }
                }

                // Timeline ribbon with speaker color blocks and clickable Moment pin markers.
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.line.opacity(0.65))
                            .frame(height: 12)

                        Canvas { ctx, size in
                            for slice in pulse.slices {
                                let x = slice.startFraction * size.width
                                let w = max(2, (slice.endFraction - slice.startFraction) * size.width)
                                let rect = CGRect(x: x, y: 1, width: w, height: size.height - 2)
                                let color: Color = slice.isYou
                                    ? Theme.accent
                                    : Color.speakerHue(slice.hueIndex, isDark: colorScheme == .dark)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.88)))
                            }
                        }
                        .frame(height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { val in
                                    guard hasAudio || pulse.duration > 0 else { return }
                                    let frac = min(max(val.location.x / width, 0), 1)
                                    onScrub(frac * pulse.duration)
                                }
                        )

                        // Key moment markers along the top edge.
                        if pulse.duration > 0 {
                            ForEach(moments) { m in
                                let x = min(max((m.startTime / pulse.duration) * width, 4), width - 4)
                                Circle()
                                    .fill(Theme.surface)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().fill(Theme.accent).padding(1.5))
                                    .position(x: x, y: 6)
                                    .help("\(m.kind.label): \(m.title) (\(TimeFormat.clock(m.startTime)))")
                                    .onTapGesture { onScrub(m.startTime) }
                            }
                        }
                    }
                }
                .frame(height: 14)

                // Speaker talk-share pills (wrap cleanly onto multiple rows on narrow panes).
                WrappingFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(pulse.shares) { share in
                        let pct = Int((share.fraction * 100).rounded())
                        let dotColor: Color = share.isYou
                            ? Theme.accent
                            : Color.speakerHue(share.hueIndex, isDark: colorScheme == .dark)
                        Button {
                            if !share.isYou, !SpeakerMemory.isPlaceholder(share.name) {
                                onSelectSpeaker(share.name)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(dotColor).frame(width: 6.5, height: 6.5)
                                Text(share.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                                    .lineLimit(1)
                                Text("\(pct)%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.fg2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .help("\(share.name): \(TimeFormat.duration(share.seconds)) spoken · \(share.words) words · \(share.turns) turns")
                    }
                }
            }
            .padding(12)
            .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
        }
    }
}

// MARK: - Key Moments Tile Deck Section

struct KeyMomentsSection: View {
    @Environment(AppModel.self) private var model
    let document: MeetingDocument
    let player: PlayerModel
    let onJumpToTranscript: (Double) -> Void

    @State private var reel = HighlightReelController()
    @State private var showAllMoments = false
    @State private var addingPin = false
    @State private var pinTitle = ""
    @State private var pinKind: KeyMoment.Kind = .pinned
    @State private var renamingMoment: KeyMoment?
    @State private var renameDraft = ""
    @State private var copiedMomentID: String?

    private static let collapsedLimit = 4
    private var hasAudio: Bool { document.folder.exists(.audio) }

    private func displayedMoments(from moments: [KeyMoment]) -> [KeyMoment] {
        guard !showAllMoments, moments.count > Self.collapsedLimit else { return moments }
        // Prioritize Decisions, Pinned, and Commitments when showing the top 4 summary tiles, keeping chronological order.
        let ranked = moments.sorted { a, b in
            let pa = priority(of: a)
            let pb = priority(of: b)
            if pa != pb { return pa < pb }
            return a.startTime < b.startTime
        }
        let chosenIDs = Set(ranked.prefix(Self.collapsedLimit).map(\.id))
        return moments.filter { chosenIDs.contains($0.id) }
    }

    private func priority(of m: KeyMoment) -> Int {
        switch m.kind {
        case .decision: 0
        case .pinned: 1
        case .commitment: 2
        case .takeaway: 3
        case .question: 4
        }
    }

    var body: some View {
        let moments = document.moments
        let visibleMoments = displayedMoments(from: moments)
        if !moments.isEmpty || document.transcript != nil {
            VStack(alignment: .leading, spacing: 12) {
                headerRow(moments: moments)

                if moments.isEmpty {
                    Text("Pin a moment at the player's position to turn important stretches into visual summary cards.")
                        .font(.callout)
                        .foregroundStyle(Theme.fg2)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 235, maximum: 420), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(visibleMoments) { moment in
                            MomentTileCard(
                                moment: moment,
                                isPlaying: reel.activeMomentID == moment.id,
                                isCopied: copiedMomentID == moment.id,
                                hasAudio: hasAudio,
                                onPlayClip: {
                                    if hasAudio {
                                        reel.playSingle(moment, player: player)
                                    } else {
                                        onJumpToTranscript(moment.startTime)
                                    }
                                },
                                onJumpTranscript: {
                                    reel.stop()
                                    onJumpToTranscript(moment.startTime)
                                },
                                onToggleStar: {
                                    document.toggleMomentStar(moment.id)
                                    model.documentEdited(document)
                                },
                                onCopyQuote: {
                                    copyMoment(moment)
                                },
                                onRename: {
                                    renameDraft = moment.title
                                    renamingMoment = moment
                                },
                                onHide: {
                                    if reel.activeMomentID == moment.id { reel.stop(player: player) }
                                    document.hideMoment(moment.id)
                                    model.documentEdited(document)
                                },
                                onOpenSpeaker: { name in
                                    model.openPerson(named: name)
                                }
                            )
                        }
                    }
                }
            }
            .onDisappear { reel.stop() }
            .onChange(of: document.folder.id) { _, _ in reel.stop() }
            .alert("Rename key moment",
                   isPresented: Binding(get: { renamingMoment != nil }, set: { if !$0 { renamingMoment = nil } })) {
                TextField("Headline", text: $renameDraft)
                Button("Save") {
                    if let target = renamingMoment {
                        document.renameMoment(target.id, to: renameDraft)
                        model.documentEdited(document)
                    }
                    renamingMoment = nil
                }
                Button("Cancel", role: .cancel) { renamingMoment = nil }
            }
        }
    }

    private func headerRow(moments: [KeyMoment]) -> some View {
        let totalReelSeconds = HighlightReelPlan.build(from: moments).totalSeconds
        return HStack(spacing: 8) {
            SectionHeader(title: "Key moments")
            if !moments.isEmpty {
                Text("\(moments.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.fg2)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(Theme.bg, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line))
            }
            if moments.count > Self.collapsedLimit {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showAllMoments.toggle() }
                } label: {
                    Text(showAllMoments ? "Show top 4" : "Show all \(moments.count)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)

            if hasAudio, !moments.isEmpty {
                Button {
                    reel.toggle(moments: moments, player: player)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: reel.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        ViewThatFits(in: .horizontal) {
                            Text(reel.isPlaying
                                 ? "Stop (\(reel.currentStopIndex)/\(max(reel.totalStops, 1)))"
                                 : "Play highlights · \(TimeFormat.duration(totalReelSeconds))")
                            Text(reel.isPlaying ? "Stop" : "Highlights")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                    .foregroundStyle(reel.isPlaying ? .white : Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(reel.isPlaying ? Theme.accentFill : Theme.mark, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Play only the audio excerpts of these Key Moments back-to-back")
            }

            PinMomentAtPlayheadButton(player: player, isPresented: $addingPin) { timestamp in
                pinTitle = ""
                pinKind = .pinned
                addingPin = true
            }
            .popover(isPresented: $addingPin, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pin moment at \(TimeFormat.clock(player.currentTime))")
                        .font(.system(size: 13, weight: .semibold))
                    Picker("Kind", selection: $pinKind) {
                        ForEach(KeyMoment.Kind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    TextField("Headline, e.g. Pricing decision", text: $pinTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveCustomPin)
                    HStack {
                        Spacer()
                        Button("Cancel") { addingPin = false }
                            .controlSize(.small)
                        Button("Save Tile") { saveCustomPin() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accentFill)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(width: 260)
            }
        }
    }

    private func saveCustomPin() {
        let t = (player.currentTime * 10).rounded() / 10
        let label = pinTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        document.addCustomMoment(title: label.isEmpty ? "Pinned at \(TimeFormat.clock(t))" : label,
                                 kind: pinKind, startTime: t)
        model.documentEdited(document)
        addingPin = false
    }

    private func copyMoment(_ moment: KeyMoment) {
        let md = moment.markdownCard(meetingTitle: document.meta.title, meetingDate: document.meta.startTime)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        copiedMomentID = moment.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedMomentID == moment.id { copiedMomentID = nil }
        }
    }
}

/// Leaf button observing `player.currentTime` so 10 Hz playback ticks never re-render the Moment card grid.
private struct PinMomentAtPlayheadButton: View {
    let player: PlayerModel
    @Binding var isPresented: Bool
    let onTrigger: (Double) -> Void

    var body: some View {
        Button {
            onTrigger(player.currentTime)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin")
                    .font(.system(size: 10.5, weight: .medium))
                ViewThatFits(in: .horizontal) {
                    Text("Pin \(TimeFormat.clock(player.currentTime))")
                    Text("Pin")
                }
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            }
            .foregroundStyle(Theme.fg2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.bg, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .help("Create a Key Moment tile at the player's current timestamp")
    }
}

// MARK: - Individual Moment Tile Card

struct MomentTileCard: View {
    let moment: KeyMoment
    var meetingSubtitle: String? = nil
    let isPlaying: Bool
    var isCopied: Bool = false
    let hasAudio: Bool
    let onPlayClip: () -> Void
    let onJumpTranscript: () -> Void
    var onToggleStar: (() -> Void)? = nil
    let onCopyQuote: () -> Void
    var onRename: (() -> Void)? = nil
    var onHide: (() -> Void)? = nil
    var onOpenSpeaker: ((String) -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top bar: category pill + optional owner + star / menu
            HStack(spacing: 6) {
                MomentKindPill(kind: moment.kind)
                if let badge = moment.ownerBadge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.fg2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                }
                Spacer(minLength: 4)
                if isCopied {
                    Text("Copied")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else if let onToggleStar {
                    Button(action: onToggleStar) {
                        Image(systemName: moment.isStarred ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(moment.isStarred ? Theme.accent : (hovering ? Theme.fg2 : Theme.fg3.opacity(0.6)))
                            .hitTarget(4)
                    }
                    .buttonStyle(.plain)
                    .help(moment.isStarred ? "Unstar moment" : "Star moment")
                }
                Menu {
                    Button("Copy quote card", action: onCopyQuote)
                    Button("Open in transcript", action: onJumpTranscript)
                    if let onRename {
                        Button("Edit headline…", action: onRename)
                    }
                    if let speaker = moment.speakerName, !SpeakerMemory.isPlaceholder(speaker), let onOpenSpeaker {
                        Button("View \(speaker) in People") { onOpenSpeaker(speaker) }
                    }
                    if let onHide {
                        Divider()
                        Button("Remove tile", role: .destructive, action: onHide)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fg3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            // High-level takeaway headline
            Text(moment.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Verbatim quote preview (when available)
            if !moment.quote.isEmpty, moment.quote.caseInsensitiveCompare(moment.title) != .orderedSame {
                Text("\u{201C}\(moment.quote)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(0.45)).frame(width: 2)
                    }
            }

            Spacer(minLength: 2)

            // Footer: speaker / meeting context + Play clip & Jump buttons
            HStack(spacing: 6) {
                if let speaker = moment.speakerName, !speaker.isEmpty {
                    let clickable = !SpeakerMemory.isPlaceholder(speaker) && onOpenSpeaker != nil
                    Button {
                        if clickable { onOpenSpeaker?(speaker) }
                    } label: {
                        HStack(spacing: 5) {
                            PersonAvatarView(name: speaker, size: 18)
                            Text(speaker)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.fg2)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!clickable)
                } else if let meetingSubtitle {
                    Text(meetingSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.fg3)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onPlayClip) {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "pause.fill" : (hasAudio ? "play.fill" : "arrow.up.right"))
                            .font(.system(size: 9.5, weight: .bold))
                        Text("\(TimeFormat.clock(moment.startTime)) · \(Int(moment.clipDuration.rounded()))s")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(isPlaying ? .white : Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(isPlaying ? Theme.accentFill : Theme.mark, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(hasAudio ? "Play this \(Int(moment.clipDuration.rounded()))s moment" : "Open at \(TimeFormat.clock(moment.startTime))")

                Button(action: onJumpTranscript) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.fg2)
                        .frame(width: 22, height: 22)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .help("Open in transcript at \(TimeFormat.clock(moment.startTime))")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(isPlaying ? Theme.mark.opacity(0.65) : Theme.bg.opacity(hovering ? 0.95 : 0.72),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isPlaying ? Theme.accent : (hovering ? Theme.accent.opacity(0.35) : Theme.line),
                        lineWidth: isPlaying ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onPlayClip)
        .onHover { hovering = $0 }
    }
}
