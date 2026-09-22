---
name: pp-5205-chapter-seek-instant
created: 2026-09-22
author: claude-opus-5
type: bugfix
---

**Jira:** PP-5205, reported against the 3.3.0 RC. Branch is off
`release/3.3.0`, not `develop`.

**ADR refs:** none. The governing texts are the Wave 0 god-class LOC freeze
(`scripts/check-godclass-loc-freeze.sh`, `docs/architecture/god-class-decomposition-plan.md`)
and the audiobook area checklist, whose §7 traps 9-11 this changeset adds.

## Claims

- Choosing a chapter no longer replaces the player with a full-screen
  "Downloading…" state. The overlay's decision now takes `hasStartedPlayback`, so
  a live readiness signal going false MID-SESSION is distinguishable from the
  pre-playback window.
- A seek to a chapter whose audio is already on disk does not mute the player,
  does not publish `isLoaded = false`, and arms no load timeout — there is
  nothing for the patron to wait on. A seek to a track still being STREAMED keeps
  the previous behaviour exactly, mute included.
- A load timeout armed by an earlier streaming seek cannot fire over a
  subsequent local seek and surface "Audiobook Unavailable" on a book playing
  from disk.
- While an LCP seek is in flight, `currentTrackPosition` reports the chapter the
  patron is GOING to, as `OpenAccessPlayer` has always done on its own seek path.
- **The chapter LABEL moves on the tap, not on the seek, on BOTH surfaces.**
  On the phone the name now reads `progress.chapterTitle`, mirrored from the
  toolkit model on the SAME tick as `chapterOffset` and `chapterTimeLeft` —
  `selectedLocation.didSet` writes `currentLocation` synchronously and
  `currentChapterTitle` derives from it, so the name is right before a seek is
  issued. On CarPlay, whose taps route through `skipToChapter(at:)`, that method
  publishes the chosen chapter immediately.
- An update naming the track being LEFT cannot move the label while an explicit
  selection is in flight. The hold is keyed on track identity, so a seek that
  outlasts any timer is not dragged backwards.
- The hold is BOUNDED: a seek that never produces a position for its target
  releases after `ChapterNavigationHold.timeoutSeconds`, so a failed seek cannot
  freeze the label or deafen it to every later chapter change.
- A second tap supersedes the first, and a teardown releases the hold, so a hold
  never outlives the session that armed it.
- `selectionNeedsImmediatePublish` deliberately DISAGREES with
  `ChapterChangeDetector` on same-track / different-title pairs. The reactive rule
  must stay quiet mid-track so an anthology does not announce a crossing; the
  explicit one must not, because the patron tapped a different row.

## Anti-claims

- This does NOT remove the streaming→local requeue. It still happens lazily, at
  the first cross-track seek after the download finishes, rather than when
  `decryptedUrls` land. The requeue is made silent and fast, not eliminated; the
  right fix is a larger change to the download-completion path and is named in
  the toolkit PR's "Not done".
- **The producer was mis-identified TWICE, and both wrong fixes are still in the
  diff because both are real.** First the toolkit's `AudiobookPlaybackModel` hold
  — armed by `selectedLocation`, which the toolkit's own TOC view uses. Then
  `AudiobookSessionManager.skipToChapter(at:)` — a call-site census, run AFTER
  writing that fix rather than before, found its only callers are
  `CarPlayAudiobookBridge:187` and `CarPlayTemplateManager:597`. The phone
  presents the TOOLKIT's `AudiobookNavigationView`
  (`AudiobookMorphingPlayerView:299`), so neither reached the reported screen.
  Only the third change — the label's source — fixes what was reported.
- `AudiobookSessionPresenter`'s one-line mirror
  (`progress.chapterTitle = model.currentChapterTitle`) is **NOT covered by a
  test**. The existing presenter suite states an `AudiobookPlaybackModel` cannot
  be constructed from PalaceTests; that claim has not been re-verified here, and
  the toolkit's own tests DO construct one from `alice_manifest`. Recorded as a
  known gap, not as an impossibility.
- `audiobookSession` remains a plain `let` on `AudiobookMorphingPlayerView`, so
  the view still does not observe it. Nothing else on it is rendered there today,
  but the next value read from it inherits the same defect and nothing in the
  type system says so.
- The toolkit's `AudiobookPlaybackModel` fix is NOT what fixes the reported
  symptom in Palace. Palace renders its own `AudiobookMorphingPlayerView`, whose
  chapter label reads `audiobookSession.currentChapter`. The model's hold is
  armed by `selectedLocation`, which the toolkit's own `AudiobookNavigationView`
  uses and Palace does not. It is the same defect one layer over, fixed because
  it is real, not because it is on this screen's path. **My first diagnosis
  aimed at that model and was wrong about the producer**; the record says so
  rather than presenting one fix as covering both.
- `AudiobookSessionManager.swift` has **0 mutation points on its changed lines**
  (measured: `--diff-only` reports 0/111). The change is a switch, assignments
  and a delegation call — no comparison, boolean or return operator for
  `palace_mutate` to flip. Mutation is not a measurement for that file's delta
  and is not quoted as one.
- `AudiobookPositionPolicy.swift` scored 3/3 killed, but only 3 of 23 mutation
  points fall on changed lines, and all three are on ONE line —
  `selectionNeedsImmediatePublish`'s `!=` / `||`. `reactiveUpdate` is a guard and
  a ternary and offers nothing to mutate. "100%" describes one expression, not
  the changeset; the transition table is what covers the rest.
- This does NOT verify anything against Findaway, OverDrive, or a bearer-token
  server. LCP and the shared `OpenAccessPlayer` seek path only, plus one device.
- This does NOT change WHEN a seek is issued, retried or cancelled — only what
  is displayed while one is in flight and what is announced about it.
- The detector added here (`check-playback-ui-latch.py`) cannot see the
  timer-lifecycle half of PP-5205 — a 30s `asyncAfter` with no `DispatchWorkItem`
  handle, stacking on every re-entry is invisible to any signature-shaped check.
  It says so in its own clean output, so a green run is not read as "this file is
  clean".
- No detector is proposed for the cache-latency class itself. The wall entry
  carries the justification rather than leaving the field empty.

## Files in scope

DERIVED from `git diff origin/release/3.3.0...HEAD --name-only` plus
`git status --porcelain`, not hand-maintained.

- `Palace.xcodeproj/project.pbxproj` — registers `ChapterNavigationHold.swift`
  (both app targets) and `ChapterNavigationHoldTests.swift` (PalaceTests)
- `Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift` — BEHAVIOUR:
  `loadingOverlayState` takes `hasStartedPlayback` and branches on phase;
  `stateArmsLoadTimeout` decides arming; the 30s timer gains a cancellable
  handle; the chapter name reads `progress.chapterTitle` instead of
  `audiobookSession.currentChapter`, with the fallback extracted as
  `chapterDisplayTitle(chapterTitle:bookTitle:)`
- `Palace/Audiobooks/AudiobookSessionPresenter.swift` — BEHAVIOUR:
  `AudiobookPlaybackProgress` gains `@Published var chapterTitle`, set from
  `model.currentChapterTitle` in the SAME `model.$currentLocation` sink that
  already sets `chapterOffset` / `chapterTimeLeft`. Sharing the writer is the
  point: it makes name-vs-times disagreement unrepresentable rather than fixed
- `Palace/Audiobooks/AudiobookPositionPolicy.swift` — BEHAVIOUR: adds
  `ChapterNavigationPolicy` (the two decisions). Also gains a toolkit import for
  ONE pure String static, documented in-file as the deliberate exception to the
  file's toolkit-free rule
- `Palace/Audiobooks/AudiobookSessionManager.swift` — BEHAVIOUR: `skipToChapter`
  publishes the selection; `handlePositionUpdate` routes through the hold;
  teardown releases it. **Net CODE LOC: zero** — see "God-class freeze" below
- `Palace/Audiobooks/ChapterNavigationHold.swift` — NEW: the hold's mechanism
  (target key + bound), extracted so the hub does not grow
- `ios-audiobooktoolkit` — submodule pointer, `ca0f4ca` → `548c258`
  (ThePalaceProject/ios-audiobooktoolkit#225 and #226). Branched from the SHA
  `release/3.3.0` already pins, so the bump carries ONLY PP-5205 — toolkit `main`
  additionally holds #223 (readium pin by tag) and #224 (player localisation),
  neither of which is in this release candidate and neither of which this bump
  pulls in
- `PalaceTests/AppInfrastructure/AudiobookMorphingPlayerViewTests.swift` — overlay
  table + timeout-arming tests
- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` — the decision table
- `PalaceTests/Audiobook/ChapterNavigationHoldTests.swift` — the mechanism
- `scripts/check-playback-ui-latch.py` + `scripts/tests/test_check_playback_ui_latch.py`
  — the detector for the overlay class and its 8 tests
- `scripts/verify-pr.sh` — wires the detector; adds `--base <ref>`
- `scripts/tests/test_verify_pr_ratchet_wiring.sh` — asserts both, clean path
  included
- `docs/architecture/areas/audiobook/verification-checklist.md` — §7 traps 9-11
- `.forgeos/wall-failures/2026-09-22-cache-written-only-by-the-signal-it-outruns.md`
  + `INDEX.md`
- `.forgeos/changesets/fix-PP-5205-downloading-overlay/{fix-contract,architect-review}.md`

## Reproduction

Device, iPhone 17 Pro Max, build 509, recorded. Open a downloading LCP
audiobook, tap a later chapter in the TOC. Before: the player is replaced by a
full-screen "Downloading…" panel and the audio stops. After the overlay fix, the
residue was visible and is what the recording caught — frames 19-29 show the
chapter title reading "Chapter 18" beside `-17:48` and "11 hr 03 min remaining",
both of which belong to Chapter 42 (TOC: 42 = 17:48). The title flips at frame
30, the first frame showing audio had started.

That split IS the diagnosis. One fact reaching one row through two readers, at
two latencies, localises the producer without reading any code — recorded as a
trap in the area checklist for that reason.

## Root cause

Three layers, each uncovered by fixing the one above it.

1. `loadingOverlayState` asked "is the player loaded right now". A live readiness
   signal goes false mid-session on every cross-track seek, so the predicate
   could not tell a seek from the pre-playback window.
2. `LCPStreamingPlayer.playCallback` gated the loading state on
   `!isSeekWithinSameTrack` alone — true of ANY track change, including one whose
   every byte is local. Locality is the question that path has to ask.
3. `AudiobookSessionManager.currentChapter` is a cache written only from
   `.positionUpdated`, and a seek pauses the player — which is the absence of
   exactly that stream. The cache's only writer is the signal the user's action
   outruns.

## God-class freeze

`AudiobookSessionManager.swift` is under the Wave 0 ratchet, and the first
version of this fix tripped it: **1557 → 1593, +36**. That is the ratchet working
as designed — every reliability fix lands inside the hub because that is where
the seams are, and this was one. The mechanism moved to
`ChapterNavigationHold`, the decisions to `ChapterNavigationPolicy`, and the two
call sites collapsed to one line each; `Log.debug` moved to the collaborator that
makes the decision. The hub now measures **1557, exactly at baseline**.

## Verification

- `ChapterNavigationPolicyTests` — 11 tests, 0 failures. The transition table
  whole: {no hold, hold matches, hold mismatches} × {chapter changed, unchanged},
  plus both first-emit cells. The mismatched-hold + nil-current cell is the one
  that would leak if the hold were checked AFTER the change test.
- `ChapterNavigationHoldTests` — the mechanism, including the bound (a real
  `timeoutSeconds + 0.4` wait: a bound asserted by reading a constant is not a
  bound) and supersession by a second tap.
- `PalaceAudiobookToolkitTests/AudiobookPlaybackModelTests` — 15/15, and
  `LCPStreamingPlayerAsyncContractTests` 8/8 (23 together).
- Mutation, `--no-cache`, baseline PASS on both runs:
  `Palace/Audiobooks/ChapterNavigationHold.swift` — 3 points, **3 killed, 0
  errored**. All three are the return arms of `shouldPublish`, so `.ignore`,
  `.releaseHold` and `.applyAndRelease` are each pinned by a named test.
  `AudiobookPositionPolicy.swift` (`--diff-only` vs `origin/release/3.3.0`) — 3
  points on changed lines, 3 killed, 0 errored.
  `AudiobookSessionManager.swift` — **0 points discovered** (0/111 on changed
  lines), recorded as a gap rather than folded into a rate. See the anti-claims
  for what these rates do and do not describe.
- **The two defects an independent review caught, both mine, both post-dating the
  figures above:** (1) arming the load timeout from `.onChange` alone, which never
  fires for the state a view is BORN with, leaving `.loadError` unreachable on a
  cold open — the exact failure `.awaitingReload` exists to prevent, reintroduced
  one layer up; (2) `clearActiveSession()` not resetting the new `chapterTitle`,
  so book A's chapter would show beside book B's zeroed timecodes. Neither was
  visible to 36 green tests, because both are wiring and the tested rules are pure.
- **Red was possible, proven twice.** Forcing the toolkit's
  `positionUpdateIsForNavigationTarget` to return `true` unconditionally fails the
  pure case AND the wiring test, the latter reporting the production symptom
  verbatim (*"a tick from the track being left must not move the display"*).
  Reverted; the tree carries no mutant (`grep -c "_ = target"` = 0).
- The toolkit wiring test's first version measured the wrong thing and passed
  anyway: with `isLoaded = true` the selection reaches the mock's `play(at:)`,
  which sets `isPlaying`, which lets `DefaultAudiobookManager`'s 1-second
  now-playing poll re-publish the mock's static position between the emits. It
  was racing the timer, not asserting the gate. `isLoaded = false` routes down the
  `pendingLocation` branch, and the test says so in a comment.
- `test_verify_pr_ratchet_wiring.sh` — 5 detectors, clean AND violating paths,
  plus `--base` reaching the parser. Its own first version was wrong in the way
  this repo keeps writing down: `set -e` aborted the script on the failing
  subshell before the status could be read, which printed as the assertion
  passing.

Not verified: any Findaway / OverDrive / bearer-token fulfilment; any CarPlay
surface, though `chapterUpdatePublisher` feeds it and the publish is now strictly
EARLIER than before, never later or absent.
