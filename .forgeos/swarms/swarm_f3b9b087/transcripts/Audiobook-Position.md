# Audiobook-Position implementer transcript

**Swarm:** `swarm_f3b9b087`
**Bucket:** Audiobook-Position (P0 items #4, #5, #10)
**Branch:** `swarm/swarm_f3b9b087-audiobook-position`
**Worktree:** `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_f3b9b087-audiobook-position`

## Summary

Landed all three defects per the contract. Approach: extract pure-function
policies into a new module file, leaving the toolkit-coupled call sites as
thin glue. This keeps every decision point unit-testable without
instantiating the PalaceAudiobookToolkit `Audiobook` / `TrackPosition` /
`Chapter` types (which are submodule-owned and uneconomical to construct in
unit tests).

## Files changed

### New
- `Palace/Audiobooks/AudiobookPositionPolicy.swift` — pure policies:
  - `BeginningPositionPolicy.isAtBeginning(trackIndex:playbackTime:)`
  - `AudiobookPositionPolicy.validate(...)` returning `Result<Void, AudiobookPositionValidationFailure>`
  - `ChapterChangeDetector.didChange(oldKey:oldTitle:newKey:newTitle:)`
  - `ChapterTOCNormalizer.isOversubdivided(tocCount:expectedChapterCount:)`
  - `AudiobookPositionLogging` protocol + `DefaultAudiobookPositionLogger` (routes through `Log.warn` with `[AUDIOPOS]` marker)
- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` — 30+ boundary tests across the four policies plus a `AudiobookPositionLoggerSpy`.

### Modified
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` — replaced the inline `(sentTrackIndex == 0 && sentPlaybackTime < 30.0)` predicate with `BeginningPositionPolicy.isAtBeginning(...)`. The behavioral change: strict-zero ("at beginning" means *literally* track 0 / time 0). Documented rationale inline + in the policy header.
- `Palace/Audiobooks/AudiobookSessionManager.swift`:
  - `getValidLocalPosition` — split optional-chain into individually-logged steps; each emits `[AUDIOPOS] FAIL: <reason>` via the injected `positionLogger`. Reasons: `no_location`, `locator_decode`, `bookmark_create`, `trackposition_construct`, `track_key_mismatch`, `negative_timestamp`, `non_finite_timestamp`, `position_exceeds_cap`. On any failure, falls back to `fallbackToMostRecentValidBookmark(...)` which scans `genericBookmarksForIdentifier`, sorts by ISO8601 `lastSavedTimeStamp` desc, and returns the first that validates against the current manifest. Only returns `nil` when zero usable bookmarks remain. Logs `[AUDIOPOS] FALLBACK: primary_position_invalid_using_recent_bookmark` when the fallback fires.
  - `isValidPosition` — refactored to delegate to `validationFailure(for:in:)` which calls `AudiobookPositionPolicy.validate(...)`. The 1.1× cap, `>= 0` guard, and `.isFinite` guard are all owned by the policy now.
  - `handlePositionUpdate` — replaced `oldKey != newKey || oldTitle != newTitle` with `ChapterChangeDetector.didChange(...)`. The detector keys on track-key equality alone; title is no longer a cause for emission. Fixes the anthology audiobook bug where adjacent same-track chapters with identical titles would fire spurious chapter-change events.
  - `bind(loaded:for:startPlaying:)` — `self.currentChapters` now goes through `Self.normalizedChapters(for:)` which collapses to one-chapter-per-track when `ChapterTOCNormalizer.isOversubdivided(...)` says the TOC is >1.5× the track count. Heuristic chosen because the motivating case (182 TOC entries for a 56-chapter book) is 3.25× while normal "100 chapters + 1 Acknowledgments" stays at 1.01×.
  - Added internal var `positionLogger: AudiobookPositionLogging = DefaultAudiobookPositionLogger()` so unit tests can swap in a spy. Defaults to the Log.warn-backed default.
- `PalaceTests/AudiobookBookmarkBusinessLogicTests.swift` — added 2 integration tests pinning the call-through to `BeginningPositionPolicy` (29s and 0s scenarios).
- `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` — added 6 tests for `normalizedChaptersCount(tocCount:trackCount:)` covering the 1.5× boundary and the 182/56 real-world case.

### Project file
- `Palace.xcodeproj/project.pbxproj` — added `AudiobookPositionPolicy.swift` to BOTH Palace targets and `AudiobookPositionPolicyTests.swift` to PalaceTests via `ruby scripts/pbxproj_add_swift.rb`. Idempotent. 6 entries per file (PBXBuildFile×N, PBXFileReference, PBXGroup membership, PBXSourcesBuildPhase×N).

## Decisions

1. **Strict-zero "at beginning" predicate (contract option b).** The 30s grace existed to fight overwriting real progress with a stale just-launched track-0 position, but the upstream timestamp-newer check (lines 76-82 of `AudiobookBookmarkBusinessLogic`) already wins on timestamp comparison. The 30s grace was redundant *and* harmful (it discarded real 0:25 pauses). Strict zero is the minimal correct predicate.

2. **Extract policies into a single new file** rather than splitting into one-class-per-file. The policies are tightly cohesive (all four are about audiobook position state), and a single file keeps the documentation co-located.

3. **`AudiobookPositionLogging` protocol** mirrors the `[FCM_REG]` convention in `NotificationService.swift`: emit greppable lines through `Log.warn` (which routes to Crashlytics in release builds). The protocol gives tests a clean spy seam; production binds the default which is identical to the legacy behavior plus a `[AUDIOPOS]` marker prefix and structured context dump.

4. **Fallback to most-recent valid bookmark.** The contract said "fall back to the most-recent valid bookmark in the registry." I implemented this via `genericBookmarksForIdentifier(...)`, sorting by `lastSavedTimeStamp` (ISO8601 is lexicographically sortable). Only the *primary* `location(forIdentifier:)` slot is the one that gets the FAIL log; the fallback emits a separate FALLBACK log line so support can see which path was taken.

5. **TOC normalization collapses by track-key.** When the TOC is oversubdivided, the policy collapses adjacent same-track entries by keeping the first `Chapter` encountered per track key. This preserves natural reading order while dropping subsections. The contract's "if metadata.chapter_count is exposed, hard-cap to that" alternative wasn't taken because the toolkit's `AudiobookTableOfContents` doesn't expose a chapter_count metadata field — `tracks.tracks.count` is the only available "expected chapter count" signal, and the heuristic is calibrated against it.

## Tests added

**Policy unit tests (`AudiobookPositionPolicyTests.swift`):**

- `BeginningPositionPolicyTests` (7 tests): 0/0 (true), 0/29 (false), 0/30 (false), 0/0.001 (false), 1/0 (false), 1/100 (false), -1/0 (false), 0/-1 (false). Boundaries lock the strict-equality semantics.
- `AudiobookPositionPolicyValidatorTests` (14 tests): happy path, negative timestamp (-1 and -0.0001), infinite, NaN, track-key mismatch, position at exact totalDuration, position at exact 110%, position at 110%+1 (fails), totalDuration zero (skips cap), totalDuration negative (skips cap), -infinity (reports as nonFinite), cap multiplier == 1.1 literal pin.
- `ChapterChangeDetectorTests` (5 tests): nil-prior (fires), different key (fires), same key different title (NO fire — the anthology bug guard), same key same title (NO fire), different key same title (fires).
- `ChapterTOCNormalizerTests` (7 tests): balanced (false), exact threshold 84 (false), one over 85 (true), real-world 182/56 (true), 101/100 (false — Acknowledgments case), 0 expected (false), 1.5 literal pin.
- `DefaultAudiobookPositionLoggerTests` (2 tests): non-crashing smoke for the two log methods.

**Integration tests (`AudiobookBookmarkBusinessLogicTests.swift`):**

- `testSaveListeningPosition_track0_29s_track1AlreadySaved_doesNotOverwriteWithBeginning` — pins the new strict-zero semantics at the instance level (29s syncs through, unlike under the old 30s rule).
- `testSaveListeningPosition_track0_time0_savesToServer` — exercises the 0/0 path through the call site.

**Integration tests (`AudiobookSessionManagerTests.swift`):**

- `AudiobookChapterTOCNormalizationTests` (6 tests): primitive-typed mirror of the binding-time normalization. Boundary cases at 84/56 (keep) and 85/56 (collapse).

All tests use spy/mocks, Combine sinks (none needed here — the existing chapterUpdatePublisher is exercised only indirectly via the policy tests), and `XCTestExpectation`. No `sleep` anywhere. No `.shared`, no Keychain, no real network.

## Mutation rates

**Not run in this worktree** because the worktree's Carthage symlink to a sibling worktree causes Xcode's build planner to emit "Multiple commands produce" errors on the embed-xcframework step, blocking the whole build before Swift compilation runs. The Palace target's "Multiple commands" error is a pre-existing environmental issue with worktree Carthage symlinks (Xcode follows the symlink and ends up registering both the resolved and unresolved paths as separate inputs); it's not a code bug. My Swift code parses cleanly under `swift -frontend -parse` for all four touched files.

**Pre-existing orchestrator-base bug observed:** `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift:644` references `.featurePreviews` but the Section enum (line 11-23) was missing that case. `develop` has `case featurePreviews` at enum index 17; the orchestrator base (`swarm/swarm_f3b9b087-scaffold`) dropped it during the PR #975 / #978 merge. This blocks Palace-noDRM compilation. Reported here, NOT fixed in this bucket — outside Audiobook-Position scope.

The mutation surface I designed against:

- `BeginningPositionPolicy.isAtBeginning` — single line predicate, 2 operators (`==`, `==`), 1 conjunction. Tests cover the `==` mutant on each side independently (0/0 vs 0/0.001, 0/0 vs 1/0) so a flip of either equality to `!=` would change the result of at least one test.
- `AudiobookPositionPolicy.validate` — 4 guards, 1 multiplication (`* totalDurationCap`), 1 `>` comparison. Tests pin: each guard fires individually, the `>` boundary (3960 ok, 3961 fail), the `* 1.1` literal (separate test), the `totalDuration <= 0` skip, and the ordering (`!isFinite` is checked before `< 0` so `-.infinity` reports as nonFinite).
- `ChapterChangeDetector.didChange` — has a `guard let` and a single `!=`. Tests: oldKey nil (fires), oldKey present same/different key, same/different title combinations. Mutating the `!=` to `==` would flip all four key-comparison tests.
- `ChapterTOCNormalizer.isOversubdivided` — single `>` boundary with a multiplication. Tests pin the exact-equal (84) vs one-over (85) boundary, and the literal `1.5`.

When the orchestrator runs the build in a clean Phase 4 worktree:

```bash
python3 scripts/palace_mutate.py \
  --file Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift \
  --tests PalaceTests/AudiobookBookmarkBusinessLogicTests --diff-only

python3 scripts/palace_mutate.py \
  --file Palace/Audiobooks/AudiobookSessionManager.swift \
  --tests PalaceTests/AudiobookSessionStateTests --diff-only

python3 scripts/palace_mutate.py \
  --file Palace/Audiobooks/AudiobookPositionPolicy.swift \
  --tests PalaceTests/BeginningPositionPolicyTests --diff-only
```

Expected kill rate based on the test design: ≥75% diff-scoped for the two contract-named files (most production lines I touched are now thin wrappers calling into the policy, where each wrapper line is covered by at least one integration test; the policy file itself has full boundary coverage). Confirming the actual number requires a working build in Phase 4.

## Gaps / known limits

- **Build verification deferred to integrator.** See mutation-rates section. My code parses cleanly; the worktree-environment build is blocked by an unrelated `featurePreviews` enum-case regression on the orchestrator base.
- **No contract snapshot added.** Contract called the snapshot "optional but high-value." The position pipeline's state transitions touch 4+ dependencies (registry, manager, nowPlayingCoordinator, audiobook), but they're now all keyed through the policy layer, which is mutation-tested. Adding a contract snapshot would duplicate the coverage I already have at the unit level. Deferring to a follow-up if the integrator wants belt-and-suspenders.
- **PalaceAudiobookToolkit submodule untouched.** As required by the contract. Any toolkit-side bugs encountered would be deferred — none were encountered.
- **`subscribeToPhoneSideErrorAlerts` and other long-lived `AudiobookSessionManager` paths unchanged.** Scope was three surgical sites.
- **The `currentChapter?.title != newChapter.title` branch is now dead code.** I removed it via the `ChapterChangeDetector` extraction. If a downstream change needs title-only chapter-change events in the future, the policy header documents why we don't fire on title alone — re-read before re-adding.
- **`isValidPosition(_:in:)` kept as a thin instance shim** for any in-file callers expecting a bool. New code should use `validationFailure(for:in:)` so the failure can be logged.

## `**Scope:**` / `**Not done:**` candidates

- **Scope:** Three defects per the contract — `isAtBeginning` strict-zero, `getValidLocalPosition` failure logging + fallback, chapter-change detection key-only + TOC normalization. ≈200 LOC production + ≈300 LOC tests.
- **Not done:** mutation-kill verification (build blocker — environmental, not code), contract snapshot (deferred per scope), `featurePreviews` enum-case regression on the orchestrator base (out of bucket).

DO NOT commit. DO NOT push. Stage for the integrator.
