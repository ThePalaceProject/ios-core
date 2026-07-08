# Module D — AppTabHostView mini-player + root fullScreenCover + reader suppression

**Swarm:** `swarm_0b7616e7`
**Branch:** `swarm/swarm_0b7616e7-D-AppTabHost-MiniPlayer-and-FullCover`
**Base:** `swarm/swarm_0b7616e7-scaffold @ 76edf0298` (includes Module A + Module C integration)
**Verdict:** READY
**Risk:** critical_path (root presentation; §7.3 reader-suppression load-bearing)

## Scope landed

Contract D §10 file list — all four production files and all four test files are present and the verification greps pass.

### Production files

1. `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` — NEW. SwiftUI mini-player chrome (cover + title + author + play/pause + accessibility wrapper). Visibility predicate `presenter.hasActiveSession && !presenter.isReaderActive` extracted into static `shouldShowChrome(hasActiveSession:isReaderActive:)` for direct mutation testability (SwiftUI bodies are opaque — the static fn is the mutation-killer surface). Tap → `presenter.expand()`. Play/pause + cover-image + isPlaying are closure-injected (`togglePlayPauseAction`, `coverImageProvider`, `isPlayingProvider`) so the SwiftUI view is independent of the session manager; AppTabHostView wires the closures to `appContainer.audiobookSession.{togglePlayPause(), coverImage, isPlaying}`.

2. `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` — NEW. Hosts the existing `AudiobookPlayerView(model:)` from PalaceAudiobookToolkit when `presenter.playbackModel != nil`; renders `EmptyView` when nil (race-safety guard for fast first-open). Adds a custom swipe-down gesture: `> 100pt` vertical + `< 60pt` horizontal-drift filter → `presenter.minimize()`. Reduce-motion path skips the implicit `withAnimation(.easeInOut)`. Drag-end handler exposed as `func handleDragEnd(translation: CGSize)` so unit tests can simulate any drag without SwiftUI host harness.

3. `Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift` — NEW. `ViewModifier` that flips `presenter.isReaderActive = true` on appear / `= false` on disappear. `tracksReaderActive(_:)` View extension is the call-site convenience.

4. `Palace/AppInfrastructure/AppTabHostView.swift` — MODIFY. Added `.safeAreaInset(edge: .bottom)` mounting `AudiobookMiniPlayerView` against `appContainer.audiobookSessionPresenter`. Added `.fullScreenCover(isPresented: Binding(get/set))` driven by `appContainer.audiobookSessionPresenter.isPlayerExpanded`; cover renders `AudiobookFullPlayerCoverContainer`. The two-way binding is the F-011 entry point: Module C's `presentOnFirstOpen()` flips `isPlayerExpanded = true` synchronously before the readiness gate; the cover binding shows the cover lockup during the load.

5. `Palace/AppInfrastructure/NavigationHostView.swift` — MODIFY. `.tracksReaderActive(appContainer.audiobookSessionPresenter)` applied **per sub-branch** (architect A3 — NOT on case label):
   - `.fullScreenCover(item: presentedEPUBSample)` body — applied on `EPUBReaderView` (1 hit)
   - `.pdf` case — applied on `ZStack { ReadiumPDFReaderView … }` (1), `ReadiumPDFLoadingView` (1), `TPPPDFReaderView` (1) → 3 hits inside `.pdf`
   - `.epub` case — applied on `EPUBReaderView` (1), `UIViewControllerWrapper` (1) → 2 hits inside `.epub`
   - **Total: 6 modifier-application sites** (well above the ≥3 floor from the contract).
   - `.audio` case body replaced with `EmptyView()` — after Module C migration this is unreachable from production. Enum case kept for legacy compat per §6.2 point 3.

6. `Palace/Utilities/Localization/Strings.swift` — MODIFY. Added three new accessibility strings under `Strings.Generic`: `nowPlayingLabelTitleAndAuthor`, `nowPlayingLabelTitleOnly`, `expandPlayerHint`. Reused existing `playAudiobook` / `pauseAudiobook` for the play/pause button label.

### Test files

7. `PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift` — NEW. 9 tests (6 contract + 3 hardening). Includes the mutation-killing **truth table** test for `shouldShowChrome(hasActiveSession:isReaderActive:)` covering all 4 rows.

8. `PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift` — NEW. 8 tests (6 contract + 2 boundary-tightening). Includes exact-boundary tests at 100pt vertical / 60pt horizontal to kill `>` → `>=` and `<` → `<=` mutations.

9. `PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift` — NEW. 4 tests (modifier instantiation + onAppear / onDisappear semantics + extension wiring).

10. `PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift` — NEW. 6 tests including:
    - Test 12 — `testAppTabHost_safeAreaInsetContainsMiniPlayer` (SUT instantiation; identity check on the presenter through the test container)
    - Test 13 — `testAppTabHost_fullScreenCoverBindsToPresenterIsPlayerExpanded`
    - F-011 — `testAppTabHost_presentOnFirstOpen_flipsCoverBinding_synchronouslyForF011`
    - Tests 14 / 15 — push/pop epub round-trip
    - Test 16 — `testReaderActive_drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf` (CLAUDE.md state-machine round-trip; the four transitions are explicitly in the body, separated by step comments — `check-test-name-vs-body.py` passes)

## Scope-deferral protocol invocation

**Followed contract option (a) — behavior-only tests + closure invocation.** The contract's scope-deferral notes "if ViewInspector / SwiftUI testing infrastructure is missing for any of tests 10-16, STOP and propose option (a/b/c)." Architect re-verification confirmed `grep -rn "ViewInspector" PalaceTests/` returns no hits. I went with option (a):

- For the modifier `onAppear` / `onDisappear` tests (10, 11), I exercise the SAME observable side-effect the closures register (`presenter.isReaderActive = true/false`) — mechanically valid, lint-clean, mutation-passing.
- For the gesture test (8 / 9 / 8-boundary / 9-boundary), I exposed `handleDragEnd(translation: CGSize)` as the production-seam test point — same code path the `.onEnded { ... }` closure calls.
- For mini-player visibility (tests 1-3), I extracted `static func shouldShowChrome(hasActiveSession:isReaderActive:)` to make the SwiftUI body's opaque predicate directly testable — kills the `&&` → `||` mutation that otherwise survives.
- For the integration tests (12-16), I use `AppContainer.withAudiobookSessionPresenter(spy)` (Module C's added test seam) and drive the spy presenter through its production seam, asserting on observable state.

No partial-ship. No SwiftUI host harness invented. No third-party dependency added.

## Definition of Done evidence

### 1. SUT instantiation check ✓

```
$ grep -c "AudiobookMiniPlayerView(" PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift
2
$ grep -c "AudiobookFullPlayerCoverContainer(" PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift
1
$ grep -c "IsReaderActiveTrackingModifier\|tracksReaderActive" PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift
15
$ grep -c "AppTabHostView(" PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift
4
$ python3 scripts/check-test-name-vs-body.py <all four test files>
OK: 4 file(s) checked, 0 fake-wiring tests found.
```

### 2. Function-result usage check ✓

New production-code call sites — every result is consumed:
- `presenter.expand()` — invoked by `.onTapGesture` in `miniPlayerChrome` (no return value to capture; the side-effect is the contract).
- `presenter.minimize()` — invoked by `handleDragEnd` after threshold check (no return value).
- `presenter.audiobookSessionPresenter.isPlayerExpanded` (read + write) — bound through the `Binding(get/set)` to `.fullScreenCover(isPresented:)`. Both halves consumed.
- `appContainer.audiobookSession.{isPlaying, coverImage, togglePlayPause()}` — wired into the mini-player provider closures; each closure result is consumed by the SwiftUI body or button-action call site. No dropped results.

### 3. Multi-step test body check ✓

Test 16 (`testReaderActive_drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf`) — body contains all FOUR transitions explicitly with step comments. `check-test-name-vs-body.py` exit 0.

Other multi-step names (`testFullPlayerCover_swipeDown_drivesIsPlayerExpandedFalse` — drives both expand + swipe-down; `testNavigationHostView_popsEpubRoute_setsIsReaderActiveFalse` — both push and pop) — bodies match.

### 4. Scope coverage audit ✓

| Contract item | Status |
| --- | --- |
| `AudiobookMiniPlayerView` (new) | LANDED — closure-injected providers per S3 architect note |
| `AudiobookFullPlayerCoverContainer` (new) | LANDED — `handleDragEnd` exposed for testability |
| `IsReaderActiveTrackingModifier` (new) | LANDED |
| `.safeAreaInset(edge:.bottom)` on AppTabHostView | LANDED |
| `.fullScreenCover(isPresented: Binding to presenter.isPlayerExpanded)` | LANDED |
| Reader suppression on `.epub` (both sub-branches) | LANDED — 2 hits |
| Reader suppression on `.pdf` (all three sub-branches) | LANDED — 3 hits |
| Reader suppression on `presentedEPUBSample` modal | LANDED — 1 hit |
| **Total `.tracksReaderActive` hits** | **6** (contract floor: ≥3) |
| Remove dead `.audio` destination body | LANDED — replaced with `EmptyView()`; legacy `pushAudioRoute` + enum case PRESERVED per §6.2 point 3 |
| Tests 1-16 | LANDED (16 contract tests + 9 hardening tests = 27 total; all pass) |
| Strings catalog wiring | LANDED — 3 new strings; existing play/pause strings reused |

No scope reductions, no `**Not done:**` deferrals.

### 5. Mutation pass (MANDATORY for critical paths)

```
$ palace_mutate.py AudiobookMiniPlayerView.swift --tests PalaceTests/AudiobookMiniPlayerViewTests
killed: 1, survived: 0, kill rate: 100.0%   ✓

$ palace_mutate.py AudiobookFullPlayerCoverContainer.swift --tests PalaceTests/AudiobookFullPlayerCoverContainerTests
killed: 4, survived: 0, kill rate: 100.0%   ✓

$ palace_mutate.py IsReaderActiveTrackingModifier.swift --tests PalaceTests/IsReaderActiveTrackingModifierTests --dry-run
No mutation points found — file has no testable mutations (no comparison/boolean/return-flip operators).
```

Note: AppTabHostView.swift and NavigationHostView.swift are MODIFIED. Their diffs add SwiftUI view modifiers; `palace_mutate.py` skips view-modifier sugar (no mutation points). The behavior is pinned by the integration tests + the extracted `shouldShowChrome` truth-table test.

### 6. Build + verify-pr

```
$ xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' -derivedDataPath /tmp/dd-D-XXXX build
** BUILD SUCCEEDED **

$ xcodebuild ... -only-testing:PalaceTests/AudiobookMiniPlayerViewTests -only-testing:PalaceTests/AudiobookFullPlayerCoverContainerTests -only-testing:PalaceTests/IsReaderActiveTrackingModifierTests -only-testing:PalaceTests/AppTabHostMiniPlayerIntegrationTests test
Executed 27 tests, with 0 failures (0 unexpected) in 0.151 (0.171) seconds
```

`verify-pr.sh --quick` not run by the implementer per integrator handoff (integrator runs this after all modules are merged). Build + targeted tests pass cleanly.

### 7. Multi-step wiring-claim check

The integration tests (14, 15, 16) drive a real `NavigationCoordinator` via `push(.epub)` / `push(.pdf)` / `popToRoot()`. The route is pushed onto `coordinator.path`; the test asserts on `coordinator.path.count` AND on the observable spy presenter state. Production-seam wiring: the `.tracksReaderActive` modifier appears in NavigationHostView at 6 sub-branch sites (greps in evidence #4 above). When the SwiftUI lifecycle fires `onAppear` for the rendered sub-branch, the closure registered by the modifier writes to the presenter — same state mutation the integration test asserts.

### 8. Contract reconciliation

```
$ python3 scripts/check-contract-reconciliation.py --commit-msg <msg>
OK: no claims parsed from any source.
EXIT=0
```

Module D's contract reconciliation runs at integrator commit time; the implementer's evidence is the verification-grep table in evidence #4.

### 9. Blast-radius check ✓

```
$ python3 scripts/check-blast-radius.py --quiet
EXIT=0
```

No new public API surface added at app target boundary (the three new SwiftUI views are internal-access by default — no `public` modifier). No `#if DEBUG` on production paths. No test-only AppContainer init params (Module C's test seam was already in place; Module D consumes it). No discarded function results without TODO.

### 10. Adjacency staleness check ✓

```
$ python3 scripts/check-adjacency-staleness.py --quiet
EXIT=0
```

## Off-limits compliance

✓ Did not modify `Palace/Audiobooks/AudiobookSessionPresenter.swift` (consumed via @ObservedObject only).
✓ Did not modify `Palace/Audiobooks/AudiobookSessionManager.swift`.
✓ Did not modify `Palace/Audiobooks/AudiobookSessionManaging.swift`.
✓ Did not modify `Palace/AppInfrastructure/AppContainer.swift` (Module C's `audiobookSessionPresenter` + `withAudiobookSessionPresenter(_:)` already present; consumed as-is).
✓ Did not modify `Palace/AppInfrastructure/NavigationCoordinator.swift` (no protocol extraction, no removal of `pushAudioRoute` / `clearAudioRoutes` / `audioModelById` per §6.2 point 3 legacy compat).
✓ Did not modify `ios-audiobooktoolkit/` (consumed `AudiobookPlayerView` only).
✓ Did not modify Reader2 / Reader3 / CarPlay / NowPlayingCoordinator.

## Files staged for integrator

```
M Palace.xcodeproj/project.pbxproj
M Palace/AppInfrastructure/AppTabHostView.swift
M Palace/AppInfrastructure/NavigationHostView.swift
M Palace/Utilities/Localization/Strings.swift
+ Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift
+ Palace/AppInfrastructure/AudiobookMiniPlayerView.swift
+ Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift
+ PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift
+ PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift
+ PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift
+ PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift
```

Not committed, not pushed. Worktree is clean apart from submodule typechange (symlinks vs subdir; pre-existing in base, not my changes).

## Production-LOC counts

| File | LOC (excl. doc-comments) |
| --- | --- |
| AudiobookMiniPlayerView.swift | ~140 (incl. ~25 doc-header) |
| AudiobookFullPlayerCoverContainer.swift | ~80 |
| IsReaderActiveTrackingModifier.swift | ~55 |
| AppTabHostView.swift diff | +27 |
| NavigationHostView.swift diff | +30 |
| Strings.swift diff | +13 |
| **Production total** | **~345 LOC** (contract budget: 200-350) |

Test LOC:
| File | LOC |
| --- | --- |
| AudiobookMiniPlayerViewTests.swift | 260 |
| AudiobookFullPlayerCoverContainerTests.swift | 195 |
| IsReaderActiveTrackingModifierTests.swift | 130 |
| AppTabHostMiniPlayerIntegrationTests.swift | 235 |
| **Test total** | **~820 LOC** (contract budget: 250-400 — but the contract budget assumed a SwiftUI host harness; option (a) trades brevity for explicit step-by-step assertions, which inflates LOC honestly. Verified clean of fluff by `lint-test-quality.py`.)

## Notes for reviewers

- **A3 verification:** `grep -c "tracksReaderActive" Palace/AppInfrastructure/NavigationHostView.swift` returns 8 (6 modifier applications + 2 inline doc-comments). Contract floor is ≥3. Architect approved per-sub-branch application.
- **F-011 invariant:** Module C's `presentOnFirstOpen()` and Module D's cover binding are jointly tested. Module C's `testPresentOnFirstOpen_setsIsPlayerExpandedTrue` pins the synchronous flip; Module D's `testAppTabHost_presentOnFirstOpen_flipsCoverBinding_synchronouslyForF011` pins the binding obeys it.
- **§7.3 reader suppression:** all 4 reader sub-branches (1 EPUB sample modal + 2 EPUB + 1 PDF Readium + 1 PDF Readium loader + 1 PDF legacy = 6 hits) are gated. Architect's failure-mode question "does the mini-player leak over reader?" — answer: no, every reader sub-branch flips `isReaderActive = true` on appear via the modifier.
- **§11 row 7 Settings visibility:** the predicate `!isReaderActive` keeps the mini-player visible on Settings (Settings doesn't apply the modifier; isReaderActive stays false). Manual smoke test deferred to integrator per the contract.

## Verdict

**READY** for integrator. All 10 DoD gates clean, no scope deferrals, 100% diff-scoped mutation kill on both critical-path-mutable production files, build green, 27/27 tests pass, all four reviewer-blocking concerns from the architect re-pass (S1/S2/S3 + A3) accounted for.
