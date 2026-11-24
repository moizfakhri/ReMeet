# Changelog

All notable features, architectural decisions, bug fixes, and measured performance improvements in **ReMeet** are recorded here—along with the methodology and benchmark numbers behind each optimization.

All performance numbers were measured on a **base Apple M4 MacBook Pro (16 GB unified memory, macOS 27)** using Release builds against temporary synthetic and real-world test libraries (never mutating personal data).

---

## [2026-11-24] — People & Calendar Hubs, Key Moments, Audio Guardrails, Responsive Split Layout & UX Polish

### Added
- **People Hub & Cross-Meeting Memory (`PeopleStore`, `PeopleViews`):**
  - Local people directory in `~/ReMeet/people.json` built automatically from speaker names, manual profiles, and calendar invitees, tracking meeting counts, spoken time, voiceprint seconds, free-form context notes, and per-person open commitments.
  - Supports editing profiles, merging duplicate people, resetting individual voiceprints, and filtering by *All*, *Voice*, *Soon*, or *Tasks*.
- **Apple Calendar + RFC-5545 `.ics` Calendar Sync & Schedule Filtering (`ICalendarParser`, `CalendarWatcher`, `MeetingReminder`):**
  - Combines EventKit events with subscribed Google, Outlook, and iCloud `.ics` feeds (with `RRULE`/`EXDATE` expansion, folded-line parsing, and cross-source deduplication).
  - Added `MeetingReminder.hasOnlineMeetingPlatform(_:)` and `nextOnlineMeeting(_:now:reminded:)` (covering 14 platforms: Teams, Zoom, Google Meet, Webex, FaceTime, Slack Huddle, Discord, Amazon Chime, GoTo, Whereby, Jitsi, RingCentral, BlueJeans, and Gather, plus explicit location labels like `"Microsoft Teams Meeting"` and call URLs in `notes`) so classes and physical-only calendar entries stay out of Schedule and reminder prompts.
- **Walk-In Pre-Meeting Prep Briefs & Follow-Up Composer (`MeetingPrepBrief`, `FollowUpComposer`, `ScheduleViews`):**
  - Assembles recurring series history, carryover decisions/open questions, attendee context cards, mutual open promises (*What YOU promised* / *What THEY promised you*), and one-click **Join & Record** + **Copy Brief** before meetings.
  - Added one-click **Follow-up** draft composer directly in the meeting header.
- **Prioritized Commitments Radar & Action-Item Relevance (`CommitmentsRadar`, `Documents`, `SummaryParser`):**
  - Extended `ActionItem` with `relatesToMe` (`relates_to_me`) and `dismissed` (backward-compatible JSON decoding), joint-owner detection (`"Alex and Priya"`), and 1:1 elevation.
  - Prioritizes **For you** and **Waiting on others** on top while collapsing unrelated **Other team items**, with `7d` / `30d` / `All` recency filters, hover `...` relevance overrides, and one-click dismissal across both meeting summaries and Commitments Radar.
- **Key Moments, Moments Gallery, Highlight Reel & Conversation Pulse (`KeyMoments`, `KeyMomentsSection`, `MomentsGalleryView`, `HubCoordinator`):**
  - Surfaces visual tile cards (*Pinned*, *Decisions*, *Commitments*, *Key Points*) inside meetings and in a searchable cross-meeting **Moments** gallery, with sequential **Highlight Reel** playback and a clickable **Conversation Pulse** speaker talk-share ribbon.
- **Audio Route Resilience, Sound Check & Live Recording Health (`AudioHealthEvaluator`, `SoundCheckView`, `LevelProbe`, `RecorderService`, `MicCapture`):**
  - Handles AirPods, Bluetooth headset, and USB/built-in mic switches cleanly mid-session via Core Audio default-device listeners, stalled-stream recovery, and live `AVAudioEngine` / sample-rate reconfiguration.
  - Added pre-call **Sound Check** sheet/card (`You` mic dB meter + 3 s voice check, `Call` meter + call audio loopback check, sample rate readout) accessible from the menu bar, onboarding, and upcoming meeting cards.
  - Added `AudioHealthEvaluator` to surface actionable warnings for OS/hardware-muted mics, digital-zero flatlined inputs, stalled Bluetooth streams, blocked call audio capture, and call-app mic mismatches.
- **Turn-Level Speaker Assignment & Clean Voiceprint Unlearning (`SpeakerMemory`, `SpeakerAssignSheet`, `MeetingDocument`):**
  - Added `KnownVoice.Contribution` (`sourceKey: "<meetingID>::<speakerID>"`) and `SpeakerMemory.unlearn(sourceKey:)` so correcting a mislabelled speaker removes the contaminated vector and recomputes the weighted centroid from remaining clean recordings; added `rankedMatches` and `expectedCallSpeakers` up to `1...12`.
  - Added `SpeakerAssignSheet` (`This turn` vs `All turns`, quick-pick speakers already in the recording, calendar invitees, People directory chips, and clear/unlearn action) plus quick-pick People menus and dismissible suggestions in `MeetingDetailView`.

### UI / UX Polish & Bug Fixes
- **Responsive Window Resizing & Narrow 3-Column Split Fix (`MeetingWindowRoot`, `WindowChrome`, `TranscriptInspector`, `HubComponents`):**
  - Replaced SwiftUI `.inspector(isPresented:)` (which triggered a macOS 27 `SplitViewChildController.hostingController(_:didUpdateMinSize:maxSize:)` constraint loop at narrow widths) with a `GeometryReader`-driven, user-draggable split pane (`240–480 pt`) and dynamic `minWindowWidth` (`760` closed, `840` 3-column, `680` collapsed sidebar; auto-collapses sidebar below `920 pt` when opening Transcript).
  - Added `WidthTrackingScrollView` (`intrinsicContentSize = noIntrinsicMetric` + async layout flush) so `NSTextContainer` tracks viewport width without right-edge transcript clipping.
  - Added `ResponsiveDocumentScroll` and `WrappingFlowLayout` across detail views, stacked `MeetingChatPanel` inputs cleanly on narrow panes (`compact: width < 400`), wrapped `ConversationPulseBar` talk-share pills, made `PlayerCapsule` scrubbers flexible, and aligned `PeopleViews` stat card heights.
- **Visual Clutter Reduction (`MeetingSidebar`, `TranscriptInspector`, `MomentsGalleryView`, `ScheduleViews`):**
  - Switched workspace tabs to icon-only buttons with `.help(...)` hover tooltips, replaced the persistent `"Add context or AI export folder..."` card under configured folders with a dismissible one-time setup hint for empty folders plus hover folder-settings actions, replaced `"⌘F to find"` text with a search button tooltip, and removed redundant captions.

### Performance & Efficiency Measurements
Measured on a base M4 MacBook Pro (16 GB, macOS 27) running the Release build against a fresh 150-meeting synthetic dataset (with FTS5 `index.sqlite`, hybrid RAG `chunks.sqlite`, People directory, Commitments radar, Key Moments, `HubCoordinator`, and calendar sync initialized):
- **Launch (`menubar.ready`, 5 runs):** **207–327 ms** (median **284.9 ms**: `207.2`, `283.4`, `284.9`, `286.8`, `326.9 ms`).
- **150-meeting library scan off main (`library.loaded - launch.end`):** **17.3–49.6 ms** (median **19.6 ms**, off the main thread).
- **Window open (`window.open.request` → `window.appear` / `document.shown`):** **170–208 ms** to window appear (median **192.6 ms**); **545–583 ms** first open to document shown (median **565.0 ms**); **92–105 ms** on window reopen (median **97.9 ms**).
- **Idle CPU / power / memory (60 s across 12 samples):** **0.03% CPU**, **0.03 power**, **35 MB** `phys_footprint` (`35M+` in `top`).

### Verification
- `ReMeetKit` unit tests (`swift test --package-path Packages/ReMeetKit`): **156 / 156 passed** across 38 suites (including `AudioHealthTests`, `HubFeaturesTests`, and `PolishFeaturesTests`).
- `scripts/selftests.sh`: **76 / 76 passed** (`bubble` 26/26, `compress` 19/19, `player` 8/8, `search` 11/11, `backends` 6/6, `processmonitor` 3/3, `tapfilter` 3/3).
- Additional Release `--selftest` checks: `window` (**8/8**), `folders` (**8/8**), `bughunt reloadthen` (**3/3**), `bughunt queuedrain` (**5/5**), `bughunt callwarning` (**1/1**).
- Full Light & Dark offscreen snapshot verification across all rendered views (including `meeting-narrow-inspector`, `commitments-radar`, `schedule-prep`, `people-detail`, `moments-gallery`, and `sound-check`).

---

## [2026-11-21] — AI Agent Markdown Export, Startup & Idle Efficiency, NSTextView Transcript, Screen-Share Hiding, and UI Redesign

### Added
- **Per-Folder AI Markdown Export (`MeetingExporter`)**
  - Each in-app ReMeet folder can now bind to a local directory on disk (**Edit Folder → AI Export Folder**), automatically writing self-contained Markdown files named `YYYY-MM-DD_HH-mm_<slug>.md`.
  - Files include structured **YAML frontmatter** (`meeting_id`, `title`, `date`, `duration`, `folder`, `call_app`, `status`, `speakers`), folder context, timestamped user notes, summary, decisions, GitHub-flavored `- [ ]` / `- [x]` action item checkboxes, open questions, and the full speaker-attributed transcript—letting AI coding agents (Claude Code, Cursor, etc.) read meeting history directly from a folder instead of manual copy/paste.
  - **Lifecycle sync:** Tracks `exportedMarkdownPath` in `meta.json` so renaming a meeting, editing notes, toggling action items, renaming/merging speakers, or moving a meeting between folders updates/moves the exported `.md` in place without leaving duplicates; moving a meeting to Trash removes the exported `.md`.
  - **UI & menu access:** Added **Export All Meetings Now** and **Open Export Folder in Finder** in folder context menus, **Export Markdown… (`⇧⌘E`)** in the toolbar/Meeting menu/sidebar context menu, **Reveal Exported .md**, and a one-click **Folder** picker chip directly in the meeting detail header.
- **Title-Free Screen-Share Hiding & Global Pill Toggle (`⌥⌘H`)**
  - Upgraded `ScreenShareMonitor` and `ScreenShare` detection to work **without** requiring macOS Screen Recording permission (where macOS redacts `kCGWindowName` to `""` for all third-party apps):
    - Added BSD `proc_listallpids` + `proc_name` inspection alongside `NSWorkspace` to reliably detect helper binaries (`CptHost` / `zoomCptHost` for Zoom, `screencapture` for macOS screen recording).
    - Added window-layer + display-bounds analysis (`kCGWindowLayer > 0` spanning ≥ 85% of an active display via `CGGetActiveDisplayList`) to detect Teams and Zoom full-display sharing border overlays even when window titles are redacted, while ignoring normal `layer == 0` windows and small floating call PIPs.
  - Added customizable global shortcut **`⌥⌘H`** (**Hide or show recording pill**) and **Settings → General → Auto-hide pill when screen sharing is detected** (on by default), plus documented zero-bubble mode (menu bar timer + on-demand `⌥⌘N` note box).
- **Hybrid Launch & Reliable Window Activation**
  - Login Item launches (`keyAELaunchedAsLogInItem`) stay silent in the menu bar with 0% idle CPU.
  - Interactive launches from Spotlight, Applications, Finder, or Dock immediately open and reliably raise the meetings window (fixing `.accessory` → `.regular` activation races on first open).

### Performance & Efficiency Improvements
- **Weeve-Style `NSTextView` Transcript Renderer (`TranscriptInspector`)**
  - *Problem:* Rendering transcripts with a SwiftUI `FlowLayout` created one `Button` + `Text` + modifiers per spoken word (~8,000–10,000 SwiftUI views for a 402 KB / 1-hour meeting), with uncached double `sizeThatFits` passes and 10 Hz full-view recomputation during playback.
  - *Fix:* Replaced with an AppKit `NSTextView` + `NSAttributedString` renderer using binary-search word lookup ($O(\log W)$) and `NSLayoutManager` temporary attributes for 10 Hz active-word highlighting (zero text relayout, zero SwiftUI diffing), while preserving click-word-to-play, Shift-click / drag-select voice naming, native text copy, and instant `⌘F` find.
- **Off-Main Document Loading & Zero-I/O SwiftUI Render Passes**
  - Restored asynchronous `MeetingDocument.load` off the main thread with an instant in-RAM title placeholder (eliminating main-thread stalls when decoding 400 KB `transcript.json` + 100 KB `diarization.json` on sidebar clicks; measured **17–20 ms** off-main decode-to-render).
  - Precomputed `wordCount`, `originalAudioURLs`, `hasSystemTrack`, `reprocessStart`, `notesChangedSinceSummary`, `callSpeakers`, `speakerClips`, and `speakerAlike` off-main on load/edit—eliminating all `FileManager` `stat()` calls, word splits, and voiceprint cosine-similarity loops inside SwiftUI `body`.
  - Moved `MeetingChatThread` loading off the main thread and removed `.id(folder)` full-tree teardown on meeting switch.
  - Isolated `player.currentTime` in a leaf `AddNoteAtPlayheadButton` view and guarded `PlayerModel` observer writes so 10 Hz playback ticks no longer invalidate `NotesSection`.
  - Pre-indexed sidebar folder lists once per render and cached `DateFormatter` instances in `MeetingRow`.
- **Launch, Idle Memory & Background Thread Hygiene**
  - Fixed **MLX embedder idle memory leak** in `ChunkEmbeddingBackend`: added `unload()` with automatic 30 s idle release + `Memory.clearCache()`, unloaded on recording start and app quit, and cached LM Studio / MLX availability probes (30 s TTL, 0.5 s loopback timeout).
  - Reduced `ChunkIndex.sync` SQLite metadata queries from **$O(N^2)$ to $O(N)$** (1 table read per sync instead of 1 per meeting; single-row lookup on per-meeting `refresh`).
  - Stopped redundant search/chunk reindexing on pipeline stage-start ticks (`ProcessingQueue.onContentChange`).
  - Moved `recoverInterruptedRecordings`, SQLite DB initialization (`index.sqlite` / `chunks.sqlite`), EventKit calendar fetches (`CalendarWatcher`), Core Audio process listeners (`AudioProcessMonitor`), and recording screen-share checks (`ScreenShareMonitor`) off the main thread.
  - Removed synchronous `LSRegisterURL` on every app launch (`install.sh` handles registration at install time) and cancelled the 240 s timeout task on completion in `ClaudeSonnet`.
- **Measured Results (150-meeting synthetic library, Release build on M4 16 GB):**
  - **Idle CPU / Power / Memory:** **0.00% CPU**, **0.00 power**, **30 MB** physical footprint (with both FTS5 and hybrid chunk indexes present).
  - **Launch to menu bar ready:** **210–248 ms** (median **242.9 ms**).
  - **150-meeting library scan (off-main):** **20–40 ms** after `launch.end`.
  - **Document decode & display (off-main):** **17–20 ms**.

### UI / UX Redesign & Bug Fixes
- **Audio import preserves original recording date (`AudioImport`, `AppModel`):** Importing an existing audio file now uses the file's original creation date (embedded container `.creationDate` metadata first—preserving Voice Memos / AirDropped `.m4a` dates—then filesystem creation/earlier modification date) for the meeting folder name, `meta.startTime`/`endTime`, sidebar date grouping, and AI Markdown export filename instead of the import timestamp.
- **Editable meeting date & time (`MeetingDetailView`, `MeetingDocument`, `MeetingLibrary`):** Clicking a meeting's date/time in the header opens a calendar + time popover to adjust `startTime` (preserving duration and `endTime`), immediately re-sorting the sidebar, rewriting `summary.md`, updating the search index, and renaming/updating any auto-exported AI `.md` file.
- **Liquid Glass & scroll collision fixes (`MeetingSidebar`, `MeetingDetailView`):**
  - Replaced `.safeAreaInset(edge: .bottom)` in `MeetingSidebar` with a `VStack(spacing: 0)` separating `List` and the **Import / Settings** footer so scrolled rows clip cleanly above the `Divider` and never bleed through the Liquid Glass sidebar footer.
  - Raised the solid `Theme.surface` dock beneath `PlayerCapsule` from `54 pt` to `76 pt` (above the capsule's `64 pt` top edge, with a `28 pt` fade gradient above it) so scrolled headings and action items fade out cleanly before reaching `PlayerCapsule`'s Liquid Glass surface.
  - Added `.tint(Theme.accentFill)` to prominent buttons in `MeetingDetailView` and `FolderEditorSheet` for consistent dark-mode contrast.
- Visually audited all views in Light and Dark mode via `--snapshots` renderer:
  - **Meeting Detail:** Reorganized into a clean 2-row header (Row 1: non-truncating date/time/duration/words + app pill; Row 2: pill chips for Folder, Call speakers, and Engine/Wording), placed **Summary**, **Action items** (with owner/due pills), and **Your notes** immediately above the fold, collapsed **Speakers** into a tidy disclosure card with an unnamed-speaker badge, and added a bottom fade gradient above the floating player.
  - **Chat bar:** Collapsed idle chat from a 150 pt card into a sleek 1-row expandable ask bar; removed `.defaultAction` Return hijack that conflicted with title/note editing.
  - **Player capsule:** Replaced overlapping missing-audio text with a clean single-line `"No audio on disk"` pill and added frosted contrast backing.
  - **Sidebar & Settings:** Fixed dark-mode invisible section headers, Settings SF Symbol icons, `▲ Failed` status text, and dark-on-dark prominent buttons (`Start recording`, `Note`, `Stop`, `Retry`, `Ask`); moved `+` (New Folder) to the Folders header and **Import** to the bottom footer; eliminated sidebar date truncation.
  - **Speaker naming:** Restored inline name editing directly inside each speaker row and stopped clip preview audio on meeting switch/disappear.

### Verification
- `ReMeetKit` unit tests: **137 / 137 passed** across 33 suites (including new `MeetingExporterTests` and title-free `ScreenShare` tests).
- In-app self-tests: `bubble` (26/26), `compress` (19/19), `player` (8/8), `search` (11/11), `backends` (6/6), `processmonitor` (3/3), `tapfilter` (3/3), `folders` (8/8), `window` (8/8), `bughunt reloadthen` (3/3) — **all passing**.

---

## [2026-11-16] — Meeting Chat & Hybrid Local RAG (Phases 1 & 2)

### Added
- **Local Chunk Index & Hybrid Retrieval (`ChunkIndex`, `MeetingChunks`, `ChunkEmbeddingBackend`):**
  - Built a local SQLite FTS5 + vector-embedding chunk store (`chunks.sqlite`) indexing transcript turns, summary bullets, and user notes per meeting, scoped to *This meeting*, *This folder*, or *All recordings*.
  - Hybrid retrieval: cosine similarity top-K shortlist reranked with BM25 FTS5 (boosted for summaries and notes); automatically falls back to pure FTS5 when no embedding model is present and reindexes when one appears (supports local MLX embedders or LM Studio embedding models).
- **Meeting Chat (`MeetingChatPanel`, `MeetingChatService`, `⌘L`):**
  - Multi-turn Q&A with persistent per-meeting chat threads, follow-up query augmentation, clickable timestamped source citation pills that jump directly to the cited meeting and moment, and configurable answer backend (Claude Sonnet or offline MLX Qwen3 4B).
- **Public Repository Polish:** Added MIT `LICENSE`, public `README.md` with light/dark mode screenshots, and scrubbed personal data from tests and docs.

---

## [2026-11-05 – 2026-11-10] — Voice Identity, Word Playback, Audio Import, Folders & Sonnet Cleanup

### Added
- **Word-Level Playback & Highlighting (`WordLayout`, `SpeechStages`):** Preserves per-word timestamps from Parakeet TDT (falling back to proportional word spread when unavailable); click any word to seek and play, with live spoken-word highlighting.
- **Cross-Meeting Speaker Memory & Merging (`SpeakerMemory`, `SpeakerTracks`):** Stores WeSpeaker 256-dim voiceprint embeddings in `voiceprints.json`, suggests known speaker names in future meetings (threshold 0.62, margin 0.07), lets users name a single voice or merge duplicate clusters, and triggers debounced Sonnet wording + summary refresh after names settle.
- **Audio Import (`AudioImport`):** Import existing audio files (`.mp3`, `.wav`, `.m4a`, `.aiff`) into the same diarization, transcription, and summarization pipeline.
- **Folders with Context (`MeetingCollections`):** Dropdown sidebar folders with drag-and-drop assignment and reordering; per-folder context notes feed directly into meeting summaries and **Copy for AI**.
- **Copy for AI (`AIContextMarkdown`, `⇧⌘C`):** One-click plain Markdown export to clipboard containing header metadata, folder context, user notes, summary, action items, and full speaker-labeled transcript.
- **Optional Claude Sonnet 5.5 Text Pass (`ClaudeSonnet`, `HaikuBridge`):** Runs local draft first, then sends text-only transcript to Claude CLI for wording/spelling cleanup and summarization (with automatic fallback to on-device MLX Qwen3 4B if offline or unauthenticated; zero audio sent, zero API keys stored).
- **Safe Stop & Transcription Redo:** Stop preserves last completed transcript/summary without losing audio; users can redo transcription with Parakeet or Cohere or re-run speaker splitting per meeting.

### Fixed
- Prevented launch crash when `Meeting` menu built commands before `AppModel` was injected into SwiftUI environment.
- Fixed Dock/Finder reopen (`applicationShouldHandleReopen`) when `LSUIElement` app had no meeting window visible.
- Hardened `ProcessingQueue` cancellation/draining so Metal GPU stages never race concurrent unload or quit (`SIGSEGV` in `CommandEncoder::register_output_array`).

---

## [2026-11-03] — Production Reliability Audit, Calendar Reminders, Auto-Stop & Cohere MLX

### Added
- **Accurate Transcription Engine (`CohereMLXTranscriber`):** Integrated Cohere Transcribe 03-2026 (2B, 8-bit MLX via `mlx-audio-swift`, ~3 min per hour of audio on M4) alongside Fast Parakeet TDT 0.6B v2 (Core ML, ~25 s/hr).
- **Calendar Reminders & Call-End Auto-Stop (`CalendarWatcher`, `CallEndWatcher`):** Reads macOS EventKit calendars (iCloud, Google, Outlook) to remind 1 minute before meetings and auto-name recordings; detects when meeting apps release the mic for 30 s and runs a cancelable 10 s stop countdown.
- **Stable Local Code Signing (`scripts/build.sh`):** Automatically signs Release builds with a local `"ReMeet Local Signing"` keychain certificate so macOS Microphone and System Audio permissions survive rebuilds.
- **WCAG AA Contrast & Custom App Icon:** Designed Fern light/dark OKLCH color palette (`FernPalette`, verified by unit tests for WCAG AA contrast) and custom Icon Composer app icon.

### Audit & Reliability Fixes (2026-11-03 Full Codebase Audit — 5 Critical, 6 High, 8 Medium, 9 Low)
- **Silent/short track recovery (C1):** Replaced diarizer `"No speech detected"` hard failures with per-track energy-based fallback (`EnergySegmenter`), completing truly empty recordings cleanly.
- **Thread-safe `meta.json` writes (H1):** Added process-wide `NSRecursiveLock` around read-modify-write updates; verified with 200 concurrent writers unit test.
- **Host-clock sleep alignment (H3):** Switched recording timer and note timestamps from wall clock to `mach_absolute_time` (matching audio sample clock) and rebuilt mic + process tap automatically on system wake.
- **Resilient capture & disk-full protection (C3, C4, H2, H4, H5):** Flushed half-typed bubble notes before session stop (`onWillStop`); kept call capture running while retrying mic start on AirPods handoff; added 20 s silent-call-audio permission warning; skipped bad transcription turns instead of failing the whole meeting; added 300 MB pre-record free-space guard and write-error reporting.
- **Fail-soft MLX teardown:** Drained in-flight GPU generation before unloading Metal buffers or terminating `NSApplication` to eliminate Metal shutdown crashes.

---

## [2026-11-02] — Initial Architecture, Capture Engine, Local Pipeline & Phase 4 Performance Pass

### Built (Phases 0–3)
- **Phase 0 — Lock-Free Dual-Track Capture (`Capture/`):** Native macOS 14.4+ Core Audio **Process Tap** (`AudioHardwareCreateProcessTap`) for call audio + `AVAudioEngine` for microphone—no virtual audio driver, no meeting bot, AirPods-safe, with lock-free C ring buffer (`RMChunkQueue.c`) streaming aligned WAVs straight to disk (crash-safe via `WAVRepair`).
- **Phase 1 — App Shell, Floating Note Pill & Compression:** Menu bar app, non-activating full-screen floating note bubble (`BubblePanel`), AudioToolbox/AVFoundation compression (`2 × 344 MB WAV → ALAC 16 kHz per-track + 48 kbps AAC playback mix` in **3.9 s**, 26 MB peak RAM), and resumable `ProcessingQueue`.
- **Phase 2 — On-Device Speech & Summary Pipeline:** `ModelManager` with resumable Hugging Face downloader; FluidAudio Core ML **pyannote community-1** diarization + **Parakeet TDT 0.6B v2** ASR (verified **5.4% WER** on 3-voice self-test); local **Qwen3 4B Instruct (4-bit MLX)** and LM Studio summarizers with map-reduce chunking, strict anti-hallucination prompt structure, and timestamp linking.
- **Phase 3 — Search, Smart Detection & Retention:** Incremental GRDB SQLite **FTS5** full-text search, event-driven Core Audio meeting detection (`AudioProcessMonitor`), meeting-apps-only process-filtered tap, audio retention cleanup, and automated in-app self-test suite.

### Phase 4 — First Measured Performance Optimization Pass
*Methodology:* Measured on base M4 MacBook Pro (16 GB, macOS 27), Release build, 150-meeting synthetic dataset and 59.7-minute synthetic call using `Perf.mark` (kernel `p_starttime` delta), `xcrun xctrace` Time Profiler, `top -l -s 5` (60 s averages), `footprint`, and `/usr/bin/time -l`.

| Metric | Before | After | Key Optimization |
|---|---|---|---|
| Launch to menu bar ready | 283 ms | **241 ms** *(210–248 ms in 2026-11-21)* | Deferred library scan, search sync & cleanup off main thread |
| Idle CPU / Memory (60 s avg) | 0.00% / 23 MB | **0.00% / 22 MB** *(30 MB w/ RAG)* | Purely event-driven Core Audio listeners; zero idle timers |
| Recording CPU / Power (pill visible) | 10.9% CPU, 11.7 power | **4.7% CPU, 5.0 power** (**-57% CPU/power**) | Removed implicit 20 Hz level animations, reduced timer to 1 Hz, skipped level updates when no meter visible |
| Recording CPU / Power (pill hidden) | — | **2.9% CPU, 3.4 power** | Zero meter UI work when pill hidden |
| First window open (150 meetings) | ~541 ms | **338 ms** (**-38%**) | Off-main document read, lazy transcript inspector |
| 1-hour meeting speaker diarization | 22.6 s | **15.8 s** (**-30%**) | Concurrent track diarization sharing loaded Core ML models (gated ≥ 12 GB RAM) |
| 1-hour full pipeline (compress + diarize + Parakeet + Qwen3 4B) | — | **132–181 s wall (~26× real time)**, **5.2 GB peak** | Strict sequential model load/unload (`72–100 MB` resident 5 s after completion) |
