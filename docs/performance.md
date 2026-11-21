# ReMeet performance (Phase 4)

Measured on a MacBook Pro (base M4, 16 GB, macOS 27), Release build, 2026-11-02.
All numbers are from runs of the real app binary; nothing is estimated. Test meetings were
written to temporary folders (never `~/ReMeet`).

## Summary

| What | Before | After | How measured |
|---|---|---|---|
| Launch: menu bar ready | 283 ms (median of 5) | 241 ms (median of 5) | `Perf.mark`, ms since the kernel started the process |
| Launch: meeting list loaded (150 meetings) | 6 ms on the main thread | 30-40 ms after launch, **off** the main thread | same |
| Idle CPU / memory | 0.00 % / 23 MB | 0.00 % / 22 MB | `top` 60 s average, `footprint` |
| Recording, pill visible | 10.9 % CPU, power 11.7, 39 MB | **4.7 % CPU, power 5.0**, 38 MB | `top` 60 s, real mic + system tap |
| Recording, pill hidden | — | 2.9 % CPU, power 3.4, 36 MB | same |
| Open meeting window, first time (150 meetings) | ~541 ms (median) | **338 ms** (median, 315-346) | request → main thread free |
| Open meeting window again | ~107 ms | ~90 ms | same |
| 1-hour meeting, speaker stage | 22.6 s, peak 0.8 GB | **15.8 s**, peak 1.7 GB | back-to-back A/B, 2 runs each |
| 1-hour meeting, whole pipeline | 138 s wall (26x real time), peak 5.2 GB | 132-181 s, peak 5.2 GB (see note) | `--selftest process` + `/usr/bin/time -l` |
| Memory after processing | — | 72 MB (after speech), 100 MB (after summary) | footprint 5 s after the stage |

"Power" is `top`'s POWER column (relative energy impact, same scale as Activity Monitor's
Energy Impact). `powermetrics` needs sudo, so it was not used.

## Details

### Launch and idle
- No models are touched at launch. The library scan, search-index sync, crash recovery and
  audio cleanup run in the background; the menu bar is ready at ~240 ms.
- Idle there are no timers or polling: 0.00 % CPU over 60 s. Meeting detection is purely
  event-driven (Core Audio property listeners), verified with `--selftest processmonitor`
  (2 callbacks in 6.5 s while another process grabbed and released the mic).

### Recording
Per-thread CPU (`ps -M`) showed the cost was the main thread, not audio: the audio threads
(real-time capture into the lock-free C queue, 20 ms batched writes on a background queue)
were negligible. The main-thread cost came from:
1. the pill's level bars animating continuously (implicit animation on a value that changes
   20 times a second keeps SwiftUI rendering at display rate) -> animation removed;
2. the elapsed timer publishing 4 times a second; every menu bar label change also makes
   SwiftUI rebuild the main menu (`AppKitMainMenuItem.updateMainMenu` in the profile) ->
   once per second, on the second boundary;
3. levels published even with no meter on screen -> each `LevelBars` registers while visible;
   with none visible the recorder skips level updates entirely.
Result: 10.9 % -> 4.7 % CPU with the pill, 2.9 % without; power 11.7 -> 5.0. No models are
loaded while recording (the pipeline pauses and unloads them when a recording starts).

### Meeting window
Time Profiler (`xctrace`) showed ~325 ms inside `openWindow` in SwiftUI's synchronous first
layout (`sizeAndPlaceWindow` -> `NSHostingView.minSize`). It barely depends on the number of
meetings (1 meeting vs 150: same cost). Removing parts one at a time: the detail document
cost ~250 ms and the hidden transcript inspector ~150 ms. Changes:
- the meeting document is read off the main thread (`MeetingDocument.load`), so the first
  window layout does not include it; it appears ~6-30 ms later;
- the inspector's content is built only while it is shown;
- the library scan runs off the main thread with a generation guard.
Result: ~541 -> ~338 ms for the first open per session; reopening ~90 ms. The remaining cost
is AppKit/SwiftUI creating the split view, toolbar and glass once per session. Pre-building
the window at launch would remove it but keep ~30 MB resident all day, so it was not done.

### Processing a 1-hour meeting
Synthetic 59.7-minute call (the 3-voice script looped 58 times, 6 notes), `--selftest compose`
then `--selftest process`:

| Stage | Wall time | Peak footprint |
|---|---|---|
| Compress (2 x 344 MB WAV -> ALAC + AAC) | 3.9 s | 26 MB |
| Speakers (both tracks concurrently) | 15.9 s | 1.7 GB |
| Transcribe (464 turns, Parakeet on the Neural Engine) | 21-29 s | 87-127 MB |
| Summary (built-in Qwen3 4B, ~10k-token prompt) | 90-134 s | 4.7-4.9 GB |

- Models are never in memory together: each stage loads, runs and releases (72 MB / 100 MB
  footprint 5 s after the speech / summary stages).
- Turn audio is read straight from the ALAC files; a track is never loaded whole.
- Speaker stage: running both tracks concurrently (two diarizer managers sharing the loaded
  Core ML models) took 22.4-22.9 s -> 15.7-15.9 s; peak 0.8 -> 1.7 GB, still well below the
  summary stage. Gated to Macs with 12 GB or more.
- Summary: MLX trace shows 2.16 GB weights + ~2.2 GB transient prefill buffers for a 1-hour
  transcript (peak 4.42 GB in MLX, ~4.8 GB process footprint). An 8-bit KV cache and smaller
  prefill steps were measured (4.73-4.80 GB, no meaningful change) and not adopted. The
  remaining lever is summarizing in smaller chunks, which costs time and merge quality; at
  ~4.8 GB for one stage (below Weeve's 6.25 GB on this Mac) the single pass was kept.
- Summary wall time varies 90-136 s between runs of identical code: it depends on how many
  tokens the model writes and on the Mac's thermal state during back-to-back heavy runs.
  That is why the whole-pipeline "after" figure is a range, not a single improvement.

## How to reproduce (developer)
- `scripts/perf.sh <dataset> launch|idle|record` (Release binary, temporary storage folder).
- `ReMeet --selftest dataset <dir> 150` makes the 150-meeting library.
- `ReMeet --selftest compose <speech-dir> <out> 58` makes the 1-hour meeting;
  `ReMeet --selftest process <folder> [--from stage] [--stop-after stage]` runs the pipeline
  and prints per-stage time and peak footprint.
- Time Profiler: `xcrun xctrace record --template 'Time Profiler' --launch -- <binary> ...`.

---

## Follow-up pass (2026-11-21 — post-RAG & UI overhaul)

Measured on the same M4 MacBook Pro (16 GB, macOS 27), Release build, 150-meeting synthetic
dataset (now including both `index.sqlite` FTS5 and `chunks.sqlite` RAG hybrid index):

| What | Measured | Notes |
|---|---|---|
| Launch: menu bar ready | **210–248 ms** (median 242.9 ms) | `recoverInterruptedRecordings`, SQLite DB opens/migrations, EventKit, and Core Audio process queries moved off main; redundant `LSRegisterURL` on every boot removed |
| Launch: 150-meeting library loaded | **20–40 ms** after `launch.end` | Off the main thread |
| Idle CPU / power / memory | **0.00% CPU / 0.00 power / 30 MB** | `ChunkEmbeddingBackend` now unloads MLX embedders after 30 s idle + on recording start + on quit, with 30 s TTL probe cache |
| Meeting switch decode → display | **17–20 ms** off-main | Restored async `MeetingDocument.load` + precomputed derived fields (`wordCount`, audio paths, speaker clips/likeness) off-main so SwiftUI `body` does zero `FileManager` or cosine work |
| Transcript rendering (long calls) | **AppKit `NSTextView`** | Replaced thousands of per-word SwiftUI `Button` views in uncached `FlowLayout` with `NSAttributedString` + `NSLayoutManager` temporary attributes ($O(\log W)$ word lookup, zero relayout at 10 Hz playback) |
| Chunk index sync | **$O(N)$ SQLite reads** | Fixed $O(N^2)$ full-table scan per meeting inside `ChunkIndex.sync`; stopped reindexing on stage-start ticks |
