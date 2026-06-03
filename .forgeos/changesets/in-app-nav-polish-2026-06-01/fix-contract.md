---
name: in-app-nav-polish-2026-06-01-fix-contract
type: incident
status: active
created: 2026-06-01
last_refresh: 2026-06-01
freshness_window: 30d
owners: [audiobook, general]
description: /rigorous-fix fix-contract — polish + bug-fix follow-up to feature/in-app-nav-during-playback (PR #1029)
---

# Fix-contract — in-app navigation polish phase

> User verified on Moes Max (iPhone 17 Pro Max). Three real bugs found + the originally-deferred P5 polish. Single critical-path /rigorous-fix bundle (architect-light + SoD review). Lands on `feature/in-app-nav-during-playback` in the main worktree.

**Branch:** `feature/in-app-nav-during-playback` (squashed from swarm `swarm_0b7616e7` → PR #1029)
**Base:** current `feature/in-app-nav-during-playback` tip (commit `926e59b13`, atop `origin/develop` which now includes FINDING-B/D fix via #1028)

## Scope (in)

### Bug fixes

1. **Full player has no escape (Bug 1).** `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` — add a visible chevron-down/Done button overlay that calls `presenter.minimize()`. Keep the existing 100pt swipe-down gesture as secondary affordance.

2. **Mini-player reactivity (Bug 2).** `Palace/Audiobooks/AudiobookSessionPresenter.swift` — add four new `@Published` properties mirroring the session/playback model:
   - `@Published private(set) var isPlaying: Bool`
   - `@Published private(set) var coverImage: UIImage?`
   - `@Published private(set) var currentLocation: TrackPosition?`
   - `@Published private(set) var playbackProgress: Double`
   Subscribe via Combine to:
   - `sessionManager.playbackStatePublisher` → derive `isPlaying` from `state.isPlaying` (already done for `hasActiveSession`; extend the same sink).
   - `playbackModel.$currentLocation` (toolkit `@Published public var currentLocation: TrackPosition?`) → mirror to `presenter.currentLocation`. **Re-subscribe semantics REQUIRED (post Phase 1a review):** `adoptPlaybackModel(_:)` replaces the model. Without explicit cancel+re-subscribe, the audiobook-switch path (PP-3783) leaks the prior subscription and the second book's positions never propagate. Track the playback-model subscription in a separate `private var playbackModelCancellables = Set<AnyCancellable>()` that is `.removeAll()`-cleared in `adoptPlaybackModel` BEFORE the new subscriptions go in. Add `testPresenter_adoptsNewPlaybackModel_clearsPriorCurrentLocationSubscription` to lock this contract.
   - `coverImage` — `AudiobookPlaybackModel.$coverImage` is internal. Strategy: when `adoptPlaybackModel(_:)` runs, snapshot `sessionManager.coverImage` into `presenter.coverImage` for the initial value. To handle async hi-res cover updates that arrive AFTER bind (toolkit fires `updateCoverImageAnimated(_:)` which writes the model's internal `@Published coverImage`), `AudiobookSessionManager.updateCoverImage(_:)` (Palace-side, lines around the `coverImage` accessor) must ALSO forward the new image to the presenter via `presenter.adoptCoverImage(_:)` (new method). This avoids the snapshot-staleness gap the architect-reviewer flagged.
   For `playbackProgress`: derive from `currentLocation` via a Combine `map` transform off the `$currentLocation` subscription. Use `currentLocation.durationToSelf()` if reachable, else compute `position.timestamp / track.duration` for a single-track view, else default 0. Toolkit's `playbackProgress` internal Published can't be reached; this derivation is good enough for the mini-player scrubber.

3. **Mini-player full controls (Bug 3).** `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` — replace the minimal chrome (cover + title + play/pause) with the sample-style layout:
   - Cover (left, 44x44)
   - Title + author (multi-line, truncate-tail)
   - Time label (elapsed / chapter total, or chapter remaining)
   - Skip back (`gobackward.30` SF Symbol, action calls `appContainer.audiobookSession.skipBack()`)
   - Play/pause (existing)
   - Skip forward (`goforward.30` SF Symbol, action calls `appContainer.audiobookSession.skipForward()`)
   - Scrubber (`ProgressView` bound to `presenter.playbackProgress`, full-width strip at bottom of chrome)

   **Skip-control plumbing — RESOLVED (post Phase 1a review):** `AudiobookPlaybackModel.audiobookManager` is internal-access in the toolkit, so the mini-player CANNOT reach it directly. The session manager has its own `manager: AudiobookManager?` reference (declared private), reachable via methods.

   **Plumbing pattern:** add `func skipBack()` and `func skipForward()` to the `AudiobookSessionManaging` protocol. `AudiobookSessionManager` implements them by chaining through the private `manager` reference and calling toolkit's `async func skipPlayhead(_ TimeInterval) async -> TrackPosition?` (Player.swift:108). The async→sync bridge follows the SAME pattern as `skipToChapter(at:)` at lines 524-528 — wrap in `Task { [weak self] in ... await player.skipPlayhead(±30) ... }`. Skip interval = 30 seconds hardcoded (matches toolkit's `DefaultAudiobookManager.skipTimeInterval` default).

   **Protocol-cascade — 4 test conformers MUST be updated** when adding `skipBack/skipForward` to `AudiobookSessionManaging`:
   - `SpyShimSession` (path TBD — grep `: AudiobookSessionManaging\b` in PalaceTests/Mocks/)
   - `FakeAudiobookSessionManager`
   - `FakeIntegrationAudiobookSession`
   - The fake in `PalaceTests/CatalogUI/ContinueRowSectionTests.swift`
   Each gets a no-op or call-counter implementation matching their existing test purpose. Verify via `grep -rn ": AudiobookSessionManaging" PalaceTests/` returns all conformers and each implements the two new methods.

### Modernization

4. **SwiftUI modernization (both surfaces).** `.ultraThinMaterial` background on mini-player; system tinted colors (`.tint(.accentColor)`); SF Symbols 5+ where present. Consistent visual language between mini-player chrome and full player Done overlay.

### Accessibility (originally-deferred P5 polish — design doc §8)

5. **VoiceOver focus.** Move focus into expanded full player on expand (use `@AccessibilityFocusState` + `UIAccessibility.post(.layoutChanged, argument:)`). Return focus to mini-player on minimize.

6. **Dynamic Type reflow.** Mini-player at AX1-AX5 truncates title first, then author, before hiding controls. Keep 44pt min hit targets on play/pause/skip.

7. **Reduce-motion path.** Expand/minimize transitions wrap `withAnimation` in `UIAccessibility.isReduceMotionEnabled` guard.

## Scope (out — explicitly OFF-LIMITS)

- `ios-audiobooktoolkit/` submodule. The `Player.skipPlayhead(_:)` API is already public (line 108 of `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Player.swift`); use it directly. `AudiobookPlaybackModel.skipBack/skipForward` are internal and out of reach — DO NOT reach for them.
- `Palace/Audiobooks/NowPlayingCoordinator.swift` — Now Playing + lock-screen + CarPlay sole-source-of-truth.
- `Palace/Audiobooks/PlaybackBootstrapper.swift` — warm-start invariant.
- `Palace/Audiobooks/AudiobookSessionManager.swift` migration code (presenter.adoptBook / adoptPlaybackModel / presentOnFirstOpen call sites) — DO NOT change the timing/ordering. F-011 preservation requires SYNCHRONOUS presentOnFirstOpen before the async readiness gate.
- `Palace/CarPlay/CarPlayAudiobookBridge.swift` migration code (dismissBookOnPhone → presenter.minimize) — already migrated; do NOT regress.
- `Palace/Reader2/`, `Palace/Reader3/` — not touched.
- `Palace/MyBooks/RecentlyReadingService.swift`, `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift`, `Palace/CatalogUI/Views/ContinueRowSection.swift` — Continue rows are working; don't touch.

## Verification criteria (grep-able assertions before declaring done)

### Bug 1 — Done button
- `grep -c "presenter.minimize()" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` ≥ 2 (one in existing swipe gesture, one in new Done button action).
- `grep -E "Image.systemName: \"(xmark|chevron.down)\"" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` ≥ 1 (visible icon).
- Test `testFullPlayerCover_doneButton_callsMinimize` in `PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift` exists and passes.

### Bug 2 — Presenter reactivity
- `grep -E "@Published.*var (isPlaying|coverImage|currentLocation|playbackProgress)" Palace/Audiobooks/AudiobookSessionPresenter.swift` returns 4 hits.
- `grep -c "playbackStatePublisher" Palace/Audiobooks/AudiobookSessionPresenter.swift` ≥ 1 (subscription wired).
- `grep -E "sink|assign" Palace/Audiobooks/AudiobookSessionPresenter.swift` ≥ 2 (Combine subscriptions for currentLocation + isPlaying).
- New round-trip wiring test `testPresenter_isPlayingFlipsAfterSessionPublisherEmits` in `PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift` drives `sessionManager.playbackStatePublisher.send(.playing(...))` → asserts `presenter.isPlaying == true`.
- The `isPlayingProvider` / `coverImageProvider` closure parameters on `AudiobookMiniPlayerView` are REMOVED — `grep -c "isPlayingProvider:\|coverImageProvider:" Palace/` returns 0 hits post-fix.

### Bug 3 — Mini-player full controls
- `grep -E "Image.systemName: \"(gobackward|goforward)\\." Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 2 (skip-back + skip-forward icons).
- `grep -c "ProgressView" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 1 (scrubber).
- `grep -c "skipPlayhead" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 2 (action body for skip-back + skip-forward) OR routed via a wrapping helper.
- Test `testMiniPlayer_skipBackButton_callsPlayerSkipPlayheadNegative` and `..._skipForwardButton_callsPlayerSkipPlayheadPositive` exist.
- Test `testMiniPlayer_scrubber_reflectsPresenterPlaybackProgress` exists.

### Modernization
- `grep -E "\.ultraThinMaterial|ultraThinMaterial\(\)" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 1.

### Accessibility (P5)
- `grep -E "@AccessibilityFocusState|UIAccessibility.post" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 1 each.
- `grep -E "isReduceMotionEnabled" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` ≥ 1 (already present per existing minimize path; verify still present after Done button addition).
- `grep -c "lineLimit\|truncationMode" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` ≥ 2 (title + author truncate).

### Critical-path regression preservation
- `xcodebuild ... -only-testing:PalaceTests/CarPlayTests -only-testing:PalaceTests/CarPlayIntegrationTests -only-testing:PalaceTests/CarPlayOpenAppAlertTests -only-testing:PalaceTests/CarPlayLibraryRefreshTests -only-testing:PalaceTests/CarPlayNowPlayingTemplateTests -only-testing:PalaceTests/CarPlayChapterListTests -only-testing:PalaceTests/CarPlayPlaybackErrorTests -only-testing:PalaceTests/CarPlayAudiobookBridgePresenterMigrationTests test` — 36+/36+ pass (8 classes total).
- `xcodebuild ... -only-testing:PalaceTests/LCPAudiobooksTests -only-testing:PalaceTests/LCPSessionOrphaningTests test` — 21/21 pass.
- All existing swarm tests pass: `AudiobookSessionPresenterTests`, `AudiobookSessionManagerPresenterMigrationTests`, `AudiobookMiniPlayerViewTests`, `AudiobookFullPlayerCoverContainerTests`, `IsReaderActiveTrackingModifierTests`, `AppTabHostMiniPlayerIntegrationTests` — total 71 tests.
- F-011 first-open test (`testOpenAudiobook_firstOpen_setsPresenterIsPlayerExpandedTrue_beforeReadinessGateCompletes` in `AudiobookSessionManagerPresenterMigrationTests`) still passes.
- PP-3783 switching test (`testOpenAudiobook_switchingAudiobooks_clearsPreviousPlaybackModel`) still passes.

### Mutation
- Diff-scoped on `Palace/Audiobooks/AudiobookSessionPresenter.swift`, `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift`, `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift`. Target ≥ 80% on touched lines (critical-path).

### Build + install gates
- iPhone 16 Pro sim build clean.
- iPhone 17 Pro Max device build clean.
- xcrun devicectl install on Moes Max succeeds.

## Tests required (TDD)

For every behavior, the failing test is written first.

- **Presenter reactivity** (round-trip per CLAUDE.md "round-trip wiring tests required for state machines"):
  - `testPresenter_isPlayingFlipsAfterSessionPublisherEmits` — send `.playing` → assert `presenter.isPlaying == true`; send `.paused` → assert false.
  - `testPresenter_currentLocationMirrorsPlaybackModel` — mock playback model with `currentLocation` publisher; verify presenter mirrors.
  - `testPresenter_coverImageSnapshotAtBindTime` — verify presenter.coverImage matches session.coverImage after adoptPlaybackModel.

- **Mini-player chrome**:
  - `testMiniPlayer_displaysCoverFromPresenterPublishedProperty` — set `presenter.coverImage = <UIImage>` → assert image renders (or hosted-view smoke test).
  - `testMiniPlayer_titleAndAuthor_displayFromPresenterCurrentBook`.
  - `testMiniPlayer_scrubber_reflectsPresenterPlaybackProgress` — set `presenter.playbackProgress = 0.42` → assert progress view value.
  - `testMiniPlayer_skipBackButton_action` — tap → assert action closure fired with -30 (or skipInterval).
  - `testMiniPlayer_skipForwardButton_action` — tap → assert action closure fired with +30.
  - `testMiniPlayer_playPauseButton_action_togglesViaPresenterOrSession` — tap → assert toggle invoked.

- **Full player Done button**:
  - `testFullPlayerCover_doneButton_callsPresenterMinimize` — tap → assert `presenter.isPlayerExpanded == false`.

- **Accessibility** (behavior-only since ViewInspector unavailable):
  - `testFullPlayerCover_onExpand_postsAccessibilityFocusChange` — set `presenter.isPlayerExpanded = true` → assert `UIAccessibility.post(...)` called (use a UIAccessibility shim or just structural grep + manual smoke).
  - `testMiniPlayer_truncatesTitleBeforeHidingControls_atAX5` — set Dynamic Type AX5 → assert chrome layout decision.

- **Existing 71 swarm tests + 57 CarPlay/LCP regression** must all still pass. The mini-player closure-provider tests will need updating since the API changes (closures removed → presenter @Published).

## Acceptance

- All Verification criteria pass.
- `xcodebuild ... test` for the union of new + existing tests is green.
- Mutation kill rate ≥ 80% diff-scoped on the 3 touched production files.
- `scripts/verify-pr.sh --quick --diff-baseline` passes (or surfaces only known pre-existing flakes per memory `feedback_verify_pr_false_positives.md`).
- /forge-review (architect + qa_test + blast_radius) returns APPROVED on all 3.
- Build succeeds for both iPhone 16 Pro sim AND iPhone 17 Pro Max device.
- App installs cleanly on Moes Max via devicectl.

## Risk callouts

- **Closure-provider removal is a breaking API change for `AudiobookMiniPlayerView.init`.** Callers (currently only `AppTabHostView.swift:111`) must update. Existing `AudiobookMiniPlayerViewTests` will need rewriting — they currently construct the view with closure providers. This is acknowledged scope; tests will be updated 1:1 to use a stubbed presenter instead.
- **Skip-control plumbing — resolved above, scope item 3.** AudiobookSessionManager has its own `manager: AudiobookManager?` reference (declared private) — toolkit's `Player.skipPlayhead` is public — so adding `skipBack()`/`skipForward()` to AudiobookSessionManaging + implementing on the manager via Task is correct. No toolkit change required.
- **CarPlay regression risk.** Bug 2's presenter reactivity changes change WHEN/HOW the presenter publishes. CarPlay subscribes to `sessionManager.playbackStatePublisher` directly (not via presenter), so reactivity changes here should be invisible to CarPlay. Verified by running the 36 CarPlay tests as a regression gate.
- **VoiceOver focus shift** can cause unintended announcements. Use `@AccessibilityFocusState` (newer API) where supported; fall back to `UIAccessibility.post(.layoutChanged, ...)` for broader iOS support.
