---
name: pp-4951-chapter-completion-not-a-pause
created: 2026-08-26
author: claude-opus-5
type: bugfix
tracking: PP-4951 — the app-side half. A chapter ending is not a pause. The toolkit half (which chapter the completion signal names, what position it saves, and the toolkit's own playback model) is ios-audiobooktoolkit PR #221, merged at 0357f471, authored by a parallel session; this branch is the ios-core consumer that a toolkit worktree cannot reach.
related_prs: []
---

# Intent: PP-4951 — a chapter ending is not a pause (app side)

`AudiobookSessionManager.handleManagerState` treats the toolkit's
`.playbackCompleted` signal as "playback stopped": it sets `isPlaying = false`
and moves the session to `.paused`. That signal does not mean the patron stopped
listening. It means one chapter ended and the next is starting. Nothing on that
path calls `player.pause()`; the audio runs straight through.

On Findaway — every DRM audiobook — the signal fires at every chapter boundary
and always has, so the app has been flipping itself to paused once per chapter
for the whole of every DRM title.

## Reproduction

Open any Findaway (DRM) audiobook and listen across a chapter boundary. At the
moment the chapter ends, `AudiobookSessionManager` publishes `.paused` and sets
`isPlaying = false` while the audio continues into the next chapter. It is
normally masked within milliseconds by the next chapter's `.playbackBegan`,
which republishes `.playing`.

The unmasked case, which is why this is a defect rather than a tidiness problem:
the toolkit documents `FAEPlaybackChapterComplete` as sometimes arriving several
seconds late. A notification that lands AFTER the next chapter's
`.playbackBegan` leaves the session parked at `.paused` over playing audio, and
nothing recovers it — the toolkit's `AudiobookPlaybackModel` re-syncs from a
0.5s `isPlaying` poll, but this session manager has no poll, so the state stays
wrong until the patron touches a control. That is `docs/followups.md` item 21's
"plausible but UNREPRODUCED hazard"; the ordering has not been observed on a
device, and Findaway fulfilment is failing platform-wide so it cannot be driven
on hardware right now.

Mechanically reproducible without a device, and this is the record of the
proof-of-bite, so it must stay runnable as written. Two mutants, both applied to
`AudiobookPlaybackLifecycle.swift` and both verified by running them:

* `signal(for:)` returning `.stopped` instead of `.chapterCompleted` for
  `.playbackCompleted` — the real defect, reintroduced at the mapping.
  `testChapterCompleted_leavesPlayStateAlone` fails its `XCTAssertNil` with the
  actual value `(isPlaying: false, state: .paused(bookId:))`, and
  `testExactlyOneManagerStatePauses` fails with `2` != `1`.
* `playState(for:bookId:)` with the ternary arms swapped —
  `testPlaybackBegan_reportsPlayingAndPairsWithTheMatchingState` and
  `testPlaybackStopped_reportsPausedAndPairsWithTheMatchingState` both fail by
  name.

An earlier revision of this file named two tests that no longer exist, because
the mutation proof was recorded before the tests were renamed. The proof is only
worth keeping if it can be re-run, so the names above are the current ones.

## Root cause

`.playbackCompleted` was read as a synonym for "playback stopped" when it is not
one. It reports that a CHAPTER finished; nothing on that path stops audio.

The mistake was survivable for as long as the signal only ever fired at the end
of a book, which is true on the open-access and LCP (AVPlayer) paths: their
end-of-track handler asks "does the next track continue this chapter?" and, under
the boundary tie-break in force, both sides of that comparison resolved to the
same chapter, so the answer was always "yes" while a next track existed and the
`.completed` branch was unreachable mid-book. At the end of a book, treating it
as a stop is harmless and looks correct.

It was never true on Findaway. There the signal is not derived from a position
comparison at all — it is the audio engine's per-chapter
`FAEPlaybackChapterComplete` notification (`FAEPlaybackAudiobookComplete` is the
separate end-of-book event), so it has fired at every chapter boundary of every
DRM audiobook all along. The end-of-book-only assumption baked into this arm was
simply false for the DRM path, and the app has been pausing itself once per
chapter there ever since.

Two things kept it from being noticed. The next chapter's `.playbackBegan`
arrives within milliseconds and republishes `.playing`, so the wrong state is
almost always transient; and the toolkit's own consumer of the same signal,
`AudiobookPlaybackModel`, re-syncs from a 0.5s `isPlaying` poll that hides it
entirely. `AudiobookSessionManager` has no such poll, which is why the defect is
observable here and not there — and why fixing the toolkit consumer alone (the
other half of PP-4951) does not fix this one.

## Claims

- The `.playbackCompleted` arm no longer changes `isPlaying` or `state`. It
  still advances `currentPosition`.
- The decision is a total table over the three lifecycle signals
  (`began` / `stopped` / `chapterCompleted`), not a judgement made at each arm,
  so a signal added later cannot silently inherit whatever its arm happened to
  do. Every cell is asserted.
- The end of a BOOK still parks the UI and does not depend on this signal to do
  it, though the route differs by player: `OpenAccessPlayer` and
  `LCPStreamingPlayer` send `.stopped(beginningPosition)` from
  `handlePlaybackEnd`; `FindawayPlayer.audioEngineAudiobookCompleted` sends
  `.started(beginningPosition)` and reaches the stop indirectly via
  `shouldPauseWhenPlaybackResumes` → `performPause`. Both are pre-existing and
  unchanged.
- The table lives in a new file, `AudiobookPlaybackLifecycle.swift`, not in
  `AudiobookSessionManager`, which is a frozen god-class under the decomposition
  ratchet. The hub SHRINKS, 1579 → 1575, leaving 4 lines of headroom.
  It does NOT lower the ratchet: `check-godclass-loc-freeze.sh` prints
  `(ratchet baseline DOWN to 1575)` but writes nothing, and
  `scripts/godclass-loc-baseline.txt:163` still reads 1579 — this branch touches
  no file under `scripts/`. An earlier revision claimed the baseline moved, which
  was reading the gate's console output as the gate's state.
- `.playbackBegan` and `.playbackStopped` keep publishing
  `playbackStatePublisher.send(state)` at exactly the point in each arm where
  they always published. Neither is byte-identical any more: the assignment is
  hoisted to a single site before the `switch`, so in both arms it now precedes
  the arm's `Log` call, and in `.playbackBegan` it also precedes
  `hasEverStartedPlayback` rather
  than after. Verified inert — `hasEverStartedPlayback` is a plain `private var`
  with no observers, and nothing subscribes to `$state`/`$isPlaying`.

- `.playbackCompleted` no longer calls `playbackStatePublisher.send(state)`.
  This IS subscriber-visible and is claimed rather than left implicit: the app
  previously emitted a `.paused` to every subscriber once per chapter on Findaway
  titles. All three sinks were traced — `CarPlayAudiobookBridge.handleSessionState`,
  and `AudiobookSessionPresenter` at two points — and all three derive play/pause
  only; chapter metadata rides `chapterUpdatePublisher`. Removing it also stops a
  spurious per-chapter `.paused` reaching CarPlay.

## Anti-claims

- Does NOT change which chapter the completion signal names, or what position is
  saved when a chapter completes. Those are the toolkit half (PR #221) and are
  not in this branch.
- Does NOT deduplicate `playbackStatePublisher` emissions against the current
  state. `.playbackBegan` repeats on every buffer→resume during a skip burst and
  subscribers have always seen those repeats; suppressing them needs its own
  call-site census.
- Does NOT bump the `ios-audiobooktoolkit` submodule. The bump is sequenced
  after this change deliberately: the toolkit change makes `.completed` reachable
  at every chapter boundary on the open-access and LCP paths too, so bumping
  before this lands would extend the per-chapter false pause to those paths
  rather than fix it.
- Does NOT fix the cross-track drift filter in the toolkit's
  `AudiobookPlaybackModel` (two track-relative timestamps compared without
  checking `track.key`). Real, separate, and untickted.
- Does NOT include a device pass. The late-notification case that makes the
  stuck `.paused` observable is unreproduced, and Findaway fulfilment is failing
  platform-wide.

## Files in scope

- `Palace/Audiobooks/AudiobookPlaybackLifecycle.swift` (new)
- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `PalaceTests/Audiobook/AudiobookChapterCompletionPauseTests.swift` (new)
- `Palace.xcodeproj/project.pbxproj`

## Verification

- Seven tests, driving real `AudiobookManagerState` values rather than a bare
  enum, so the mapping the defect lives in is the thing under test. Totality is
  asserted from both ends: every tabled manager state has exactly one answer, and
  every lifecycle signal has a producing manager state — the second is why the
  enum is `CaseIterable`, and it fails if a signal is added that nothing produces
  (verified by adding one).
- Both hand-applied mutants named under **Reproduction** are killed by name.
  Neither is reachable by `palace_mutate.py`: it has no operator for an enum
  `case` arm and none for a ternary, and it reported "2 mutation points, both
  killed" against an earlier revision whose call site was still unpinned — a
  100% score on a fix that could be undone by swapping one argument.

### Full-suite runs — ALL of them, not the best one

Seven complete runs, on a dedicated simulator. Production code is byte-identical across
runs 2-7 — the last SIX, not four; verified pairwise, `git diff <tip> HEAD --
Palace/ Palace.xcodeproj/` is empty for every one of 8a30aa4f8, 7d604eac6,
5887776d0, 197f250b6, cbbcfea26 and 1d5c8f91b. Run 1 is NOT in that set: it
predates the exhaustive-switch revision of `signal(for:)` (it had `default: return
nil`) and differs from HEAD by 20 lines in the file under test. It also sat on an
earlier develop base — four PP-5025 files (`BorrowAdobeActivationStep`,
`BorrowOperation`, `TPPBook+Presentation`, `AdobeCertificate`) are absent from it
— so it differs on two independent axes. It measured a materially different
version of this diff and must not be cited as evidence about this one. It is also
the run the argument does not need: runs 2-7 alone give six runs, unchanged
production code, both families, changing members, one clean. Counts are `xcresulttool` figures, because
`verify-pr.sh` prints `passedTests` under the label "N tests".

The Passed column is NOT a suite size and moves for two independent reasons a
later reader cannot separate from the table alone: develop's own suite grew, and
this branch added a test at run 4 — runs 1-3 executed six test functions in the
new class, runs 4-7 seven.

Stated precisely, because an earlier revision said "across two rebases" and that
was wrong in BOTH directions, which two reviewers caught as two different errors.
Runs 1-7 span THREE rebases (bases `9e7c03dbd` → `b1bb7d365` → `b6de964f4` →
`1248d93fd`), and exactly ONE of them changed the test count: run 1 → run 2,
+19 of develop's PP-5025 tests. The other two added no test functions (#1419 is a
Python test, #1421 is docs-only). Quoted as DELTAS, which are the whole of
the claim and are method-independent: **+19** test functions at run 1 → run 2,
**+1** at run 4 (this branch's seventh test), **zero** at every other transition
— the last confirming #1419 (a Python test) and #1421 (docs-only) contributed
none.

Absolutes are deliberately omitted. An earlier revision quoted 7644 and 7663
under the words "measured, not recalled", and two reviewers applying the stated
method landed ~1050 higher (8683/8702, 8692/8711, 8685/8704), because the figure
came from a narrower command than the sentence described — a four-space-indent
match, and a glob missing top-level `PalaceTests/*.swift`. The deltas agreed under
every method all three of us tried. A number is checkable only if the reader can
re-run it, so the reproducible form is the command, not the total:

    git grep -h -c 'func test' <row-tip> -- 'PalaceTests/*.swift' 'PalaceTests/**/*.swift' | paste -sd+ - | bc

Run it at two row tips and difference them. The absolute it prints depends on how
you match; the difference does not.

Each row's tip is the commit the run was MEASURED on. HEAD may sit above the
last row: correcting this very section is a doc-only amend that moves HEAD
without changing a line of measured code, so labelling any row "final" is a
regress that re-falsifies itself on each correction. Verify with `git diff <row-tip> HEAD -- Palace/Audiobooks/` — empty means the row
still describes THIS BRANCH's production code. It certifies the branch's code and
nothing else; in particular it says nothing about whether the SUITE is the same,
which is a separate thing that has since changed — see the caveat below. Measured across all seven rows: run 1
DIFFERS, runs 2-7 are all empty, which is exactly the claim above.

Two scoping choices, both made after running the check rather than before. The
path is narrowed to the branch's own production directory because an unscoped
diff also picks up whatever develop contributed in a later rebase, so it turns
false the moment the branch rebases again — which it did, onto `9130a182b`, after
the last row was measured. And it excludes `PalaceTests/Audiobook/` because the
seventh test arrived at run 4, so rows 2-3 legitimately differ there; folding
tests in would make the check report a difference that the table already explains
and the claim never denied.

| Run | Tip | Passed | Failed | Failing test |
|---|---|---|---|---|
| 1 | e3fd24c26 | 8454 | 1 | `TPPBookRegistryLoadReentrancyTests.testLoad_EmitsBookStateEventsForAllBooks` |
| 2 | 8a30aa4f8 | 8475 | 2 | `BookRegistrySyncTests.test_load_downloadingWithContentOnDisk_persistsDownloadSuccessful` + `AccountsManagerStateMachineWiringTests.testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest` |
| 3 | 7d604eac6 | 8473 | 1 | `TPPBookRegistryLoadReentrancyTests…` |
| 4 | 5887776d0 | 8475 | **0** | — |
| 5 | 197f250b6 | 8477 | 1 | `AccountsManagerStateMachineWiringTests…` |
| 6 | cbbcfea26 | 8472 | 1 | `AccountsManagerStateMachineWiringTests…` |
| 7 | 1d5c8f91b | 8474 | 1 | `TPPBookRegistryLoadReentrancyTests…` |

**The clean run is run 4 of 7 and is NOT the verification.** An earlier revision
of this file published it alone, headlined "0 failed", while runs 5 and 6 were
already known to have failed. That is publishing the favourable sample: the
failing runs lived only in review conversation, which no future reader sees, and
the doc is what survives. Recorded here in full so the sampling depth is visible
rather than implied.

**Why the failures are not this diff.** They never leave two families, and the
member changes between runs — that wandering is the evidence, not the clean run.
Both pass in isolation (`AccountsManagerStateMachineWiringTests` 42/42,
`TPPBookRegistryLoadReentrancyTests` 2/2, `BookRegistrySyncTests` 18/18).
`ci-test-history.py` verdicts the AccountsManager one FLAKY from MIXED results
within single CI runs on branches predating this one; it sits at 29–50% in the
local flake report; and another session independently named both families as
known pre-existing flakes before this branch raised them. None is in Audiobooks.
No run was repeated to obtain a greener number.

**Every row predates a change in what "the suite" IS, so do not extend this table
with a post-rebase run.** The branch has since rebased onto `9130a182b` (#1422),
which added `FEATURE_DRM_CONNECTOR` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` on
the PalaceTests target in both Debug and Release. That newly compiles and runs a
body of DRM tests which were previously `#if`-skipped — verified in the pbxproj
diff, not inferred. No line of this branch changed, and the production
claims above are unaffected — but the reason is TARGET MEMBERSHIP, not file
content, and an earlier revision of this caveat got that wrong.

It said "none of its files contain an `#if` at all". False:
`AudiobookSessionManager.swift` has eleven (`grep -c '#if'`). That is true of this
branch's NEW files and was widened to all of them — the same scope-loss this
document catalogues elsewhere, committed inside the paragraph about it, and
caught by a reviewer rather than by me. The sound argument needs two clauses,
because neither covers every file alone:

* The two PRODUCTION files this branch touches are in `Palace` and
  `Palace-noDRM` and in `PalaceTests` x0. #1422's edits are confined to the
  PalaceTests target's Debug and Release configs, so they cannot reach those
  files' directives whatever the directives guard.
* The one file that IS in `PalaceTests` —
  `AudiobookChapterCompletionPauseTests.swift` — contains zero directives, so the
  changed conditions have nothing to act on there.

Membership verified with the `xcodeproj` gem, not by grepping the pbxproj. But a run taken
after that rebase measures a larger suite, and its totals are not comparable with
rows 1-7. A new row would need its own note, not a quiet append.

- Three further runs aborted early (620 and 3032 tests, and one CI-parity run)
  with `Mach error -308` / `Invalid device state`, each blaming a DIFFERENT
  in-flight test at 0.000s. Cause was a simulator-reservation bug since fixed
  (harness `8abcdb1`, ios-core #1419). Those runs are excluded as measurements of
  nothing — noted so the count of seven is not mistaken for the count of attempts.
- `verify-pr.sh --quick`: 32 checks, the only failure being the flake above.
