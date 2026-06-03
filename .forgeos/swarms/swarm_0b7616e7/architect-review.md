# Architect post-review — swarm_0b7616e7

**Verdict:** BLOCKED
**Reviewer:** architect-reviewer (Phase 1a)
**Date:** 2026-06-01
**Base branch reviewed:** `swarm/swarm_0b7616e7-scaffold` at `0f245fe2f` (design doc commit) — sits on top of `f9b09b18f` (M1 universal rigor floor).
**Branch is NOT rebased on top of `develop`** — see Finding S1 below.

The triage itself is structurally sound (4-module split honors design-doc P1+P2+P3+P4 phasing; parallelism plan is honest about the AppTabHostView conflict between B and D; off-limits lists are thorough; risk classification matches the critical-path floor). I'm blocking on **three significant findings + three advisory findings** that would burn implementer time downstream if dispatched as-is. None is a fundamental triage flaw — they're all addressable by an architect re-pass touching 3 files in the contracts dir.

Of note: I did NOT find the scope-misestimation pattern (PR #1018) that this gate was added to catch. LOC estimates (250-400 / 150-300 / 250-400 / 200-350) match the file-list footprint and the precedent set by `audiobookSession` + `withSignInModalSheetPresenter` work. The 48-vs-385-tests mismatch class is not present here.

## Findings

### Critical (block)

None.

### Significant (block)

**S1 — Swarm scaffold is BEHIND develop on a critical-path file.** The swarm scaffold branch (`design/in-app-navigation-during-playback` → `swarm/swarm_0b7616e7-scaffold`) was cut before `fd4378d95` (`fix(audiobook): stale-position-on-reborrow + LCP gate-deadlock (FINDING-D + FINDING-B)`) landed on develop. Concrete consequences:

- `stopPlayback(dismissPhoneUI:)` on this branch is the OLD signature; develop has `stopPlayback(dismissPhoneUI:persistFinalPosition:)`. Module C will modify `stopPlayback` (per the contract scope summary point 3) — if it modifies the OLD signature here, the merge-to-develop will conflict.
- The LCP gate-skip Contract C cites as the §7.5 invariant ("preserve `AudiobookSessionManager.swift:716-` area exactly") does NOT EXIST on this swarm branch. Line 716 here is `concreteRegistry.syncLocation(for:)` — a different concern. The LCP-skip (`isLCPAudiobook = loaded.decryptor != nil` branching) lives at roughly lines 723-740 ON DEVELOP, not on this scaffold. Module C cannot test or preserve a code path that isn't in its base.

**Fix:** before dispatch, rebase `swarm/swarm_0b7616e7-scaffold` onto current `develop` so the FINDING-B/D fix is present. OR (lower-cost): cherry-pick `fd4378d95` onto the scaffold and amend Contract C §7.5 to cite the new line numbers. Either is acceptable; the contract claim "preserve §7.5 LCP-streaming-gate skip" is structurally meaningless on the current base.

**S2 — Contract C cites a CarPlay test file that doesn't exist.** Module C verification criterion 5 references `PalaceTests/CarPlay/CarPlayAudiobookBridgeTests.swift` for both the migration regression-test target AND the smoke gate. That file is not in the repo. The CarPlay tests live in `PalaceTests/CarPlay/CarPlayTests.swift` as 7 test classes (CarPlayTests, CarPlayIntegrationTests, CarPlayOpenAppAlertTests, CarPlayLibraryRefreshTests, CarPlayNowPlayingTemplateTests, CarPlayChapterListTests, CarPlayPlaybackErrorTests). The grep `-only-testing:PalaceTests/CarPlayAudiobookBridgeTests test` in verification criterion 13 will return 0 tests executed — silent pass = false signal. Implementer will reasonably conclude "the file doesn't exist; I'll create it" but then the smoke gate cite still points at a phantom file.

**Fix:** Contract C should specify which existing test class to extend (likely `CarPlayTests` for the new migration regression tests, or a new sibling file `CarPlayAudiobookBridgeMigrationTests.swift` is fine if explicitly authored); update the smoke-gate `-only-testing:` selector to `PalaceTests/CarPlayTests` (or the class actually exercising `dismissBookOnPhone`); update verification criterion 13 to match.

**S3 — Cross-module DI seam left to D, will block D's tests 12-13.** Module D's tests 12-13 ("`testAppTabHost_safeAreaInsetContainsMiniPlayer`" and "`testAppTabHost_fullScreenCoverBindsToPresenterIsPlayerExpanded`") need to inject a spy `AudiobookSessionPresenter` into AppContainer-driven seams. Contract C explicitly defers this: "For this contract, the migration tests construct `AudiobookSessionManager` directly with the spy via the `audiobookSessionPresenterProvider` closure (the manager's own DI seam, no AppContainer modifier needed)." Module D's contract then says "use the AppContainer.withAudiobookSessionPresenter(_:) modifier (if Module C added it) OR construct presenter directly and pass it down". If C ships without the modifier, D's only paths are (a) the deferral-protocol path (option a/b/c) or (b) take a presenter init param on `AppTabHostView` itself. Neither is wrong, but the asymmetric AppContainer surface (signin has `withSignInModalSheetPresenter`, audiobook does not) makes future test-seam consumers more fragile.

**Fix:** Add ONE clause to Contract C: while it's modifying AppContainer to add `audiobookSessionPresenter`, it ALSO adds `_audiobookSessionPresenterOverride: AudiobookSessionPresenter?` + `withAudiobookSessionPresenter(_:)` modifier following the `withSignInModalSheetPresenter` precedent. Cost: ~25 LOC mirror of existing pattern. Benefit: D dispatches with the test seam already wired, no deferral path needed for tests 12-13. The precedent is `Palace/AppInfrastructure/AppContainer.swift` lines 33-92 + 196 + 216.

### Advisory (won't block, worth noting)

**A1 — `NavigationCoordinator` spy strategy not specified in Contract C.** Module C's tests 2, 3, 4 (`testOpenAudiobook_firstOpen_doesNotCallPushAudioRoute`, `testStopPlayback_doesNotCallCoordinatorRemoveAudioModel`, `testStopPlayback_doesNotCallCoordinatorPopToRoot`) all rely on spying on `final class NavigationCoordinator` — but `NavigationCoordinator` has no protocol extracted, is declared `final`, and the off-limits list explicitly forbids modifying it. The only paths available to the implementer are: (a) check the public state after the call (`path.count`, `path.last`, `audioModelById` count — but these are `private`), (b) extract a protocol (out of scope), (c) drop these tests in favor of presenter-side assertions only. Most likely implementer outcome: assert on observable side effects (`presenter.playbackModel != nil` after openAudiobook; `presenter.hasActiveSession == false` after stopPlayback), which IS the meaningful end-state but doesn't directly prove "the legacy coordinator was not called". That's actually fine — the legacy methods become unreachable as a result of the contract change, so absence-of-side-effect is enough. **Recommend Contract C add one sentence acknowledging this** so the implementer doesn't burn time looking for a spy seam that isn't there.

**A2 — LCP smoke-gate grep points to wrong directory.** Contract C verification criterion 14 says `ls PalaceTests/Audiobooks/LCP*Tests* 2>&1 | head -5`. That directory has no LCP test files. The actual LCP tests live at `PalaceTests/LCP/LCPAudiobooksTests.swift` + 3 siblings. The implementer will see "no LCP tests" and skip the gate. **Fix:** update the cite to `PalaceTests/LCP/`. The relevant smoke test for §7.5's LCP-streaming gate-skip is the one exercising `LCPAudiobooks.releaseResources` or any test that opens an LCP audiobook end-to-end — implementer needs guidance on which class.

**A3 — `tracksReaderActive` grep floor of 3 may be misleading.** Module D verification criterion 3 expects `>= 3 hits` on `.tracksReaderActive` in NavigationHostView. The actual reader-route enumeration is: `.epub` has 2 sub-branches (line 91 + 96), `.pdf` has 3 sub-branches (lines 56, 76, 84), `presentedEPUBSample` is 1 fullScreenCover content (line 19). A naive per-case application yields 3 hits (one per case); a thorough per-sub-branch application yields 6 hits. Both are correct depending on where the modifier is applied — at the case level vs. each rendered view. Floor of 3 is fine, but flag this for the implementer: the modifier must wrap the actual rendered reader view, not the case label, so a single `.epub` case with both branches (`EPUBReaderView` and `UIViewControllerWrapper`) needs the modifier on BOTH branches OR on a `ZStack` wrapping both. Otherwise one of the two EPUB paths leaks the mini-player.

## Verification work performed

Greps run (working dir = swarm_0b7616e7 worktree):

- `grep -rn "pushAudioRoute(" Palace/` → 3 hits: AudiobookSessionManager.swift:651 (call site), NavigationCoordinator.swift:195+196 (definition + log). Matches contract claim.
- `grep -rn "coordinator.storeAudioModel\|\.storeAudioModel(" Palace/` → 1 hit at AudiobookSessionManager.swift:650. Matches.
- `grep -rn "\.audio(" Palace/` → 3 hits: NavigationHostView.swift:104 (case), NavigationCoordinator.swift:204+207 (path.append). Matches the "removing dead destination is bounded" claim.
- `grep -rn "presentCoverArtAndNavigation" Palace/ PalaceTests/` → 2 hits, both in AudiobookSessionManager.swift (612 caller, 633 definition). Matches.
- `grep -rn "fullScreenCover\|toolbar(.hidden, for: .tabBar)" Palace/AppInfrastructure/NavigationHostView.swift` → 6 hits (line 19 sample fullScreenCover; lines 75, 83, 87, 100, 107 are five `.toolbar(.hidden, for: .tabBar)` calls). 1 sample-cover + 2 .pdf-branches + 2 .epub-branches + 1 .audio. The reader-suppression hook needs to cover the first 5; `.audio` body is being removed anyway.
- `grep -rn "playbackStatePublisher\|chapterUpdatePublisher\|errorPublisher" Palace/` → publishers consumed only by `CarPlayAudiobookBridge.swift`; CarPlayTemplateManager reads the BRIDGE's republished publishers, not the session manager's. So Module C's "CarPlay publisher contract unchanged" is structurally enforced by the existing indirection layer.
- `grep -rn "NowPlayingCoordinator\|MPNowPlayingInfoCenter" Palace/` → `NowPlayingCoordinator` is owned by AudiobookSessionManager (line 100, 212). CarPlayTemplateManager only references it in comments. Off-limits list is correct to forbid NowPlayingCoordinator changes.
- `grep -rn "AudiobookSessionManaging" Palace/ PalaceTests/` → 6 production sites consume the protocol; ZERO tests have a `class.*: AudiobookSessionManaging` mock. Module A's contract correctly says implementer must create one — and that mock will be REUSED by Module C's migration tests (via `audiobookSessionPresenterProvider` injection of a spy presenter that reads from a mock session). Cross-module mock reuse is implicit; recommend the orchestrator surface this when dispatching C.
- `grep -n "audiobookSession\|signInModalSheetPresenter" Palace/AppInfrastructure/AppContainer.swift` → confirms the audiobookSession precedent (line 149 computed + 174 static cache) AND the `withSignInModalSheetPresenter` test-seam pattern (line 92). Contract C correctly mirrors both.
- `grep -rn "AudiobookPlayerView" Palace/` → 1 hit at NavigationHostView.swift:106 (the `.audio` case body). Module D's plan to host this inside `AudiobookFullPlayerCoverContainer` is the only call site — clean migration.
- `grep -rn "stopPlayback" Palace/Audiobooks/AudiobookSessionManaging.swift Palace/Audiobooks/AudiobookSessionManager.swift Palace/CarPlay/CarPlayAudiobookBridge.swift` — finds `stopPlayback(dismissPhoneUI:)` on the protocol AND concrete class. NO `persistFinalPosition` param. **Confirms S1 — branch is behind develop.**
- `grep -rn "class.*NavigationCoordinator" Palace/AppInfrastructure/NavigationCoordinator.swift` → `final class NavigationCoordinator: ObservableObject`. Confirms A1 — no spy seam.
- `ls PalaceTests/CarPlay/` → `CarPlayAuthHelperReadinessTests.swift`, `CarPlayTests.swift`. **No `CarPlayAudiobookBridgeTests.swift`. Confirms S2.**
- `ls PalaceTests/Audiobooks/LCP*` → empty; `find PalaceTests -name "*LCP*"` → 4 files under `PalaceTests/LCP/`. **Confirms A2.**
- `grep -rn "ViewInspector" PalaceTests/` → no hits. **Confirms** Module D's deferral note about SwiftUI testing infrastructure being absent.
- Read `Palace/Audiobooks/AudiobookSessionManager.swift:505-566` to confirm `stopPlayback` signature + `dismissPlayerOnPhone` body. Line numbers match the contract (560-566, 647-654, 197-206).
- Read `Palace/AppInfrastructure/AppTabHostView.swift` end-to-end. No existing `safeAreaInset` or `fullScreenCover`. B's edit zone (init, lines 14-36) and D's edit zone (body, lines 38-116) are structurally disjoint — overlap_audit's "mechanical resolution" claim is correct.
- Read `docs/architecture/in-app-navigation-during-playback.md` end-to-end. All §6.2 / §6.3 / §6.4 / §7.1 / §7.2 / §7.3 / §7.4 / §7.5 / §11 cross-references resolved against contract scope statements; the four module contracts collectively cover P1+P2+P3+P4 with no gap and no overlap.

## Recommendation

BLOCKED. Architect should address S1 (rebase scaffold onto develop OR cherry-pick `fd4378d95`), S2 (fix CarPlay test-file references in Contract C), and S3 (Contract C adds `withAudiobookSessionPresenter(_:)` test-seam modifier). Advisory findings A1-A3 are courteous-to-fix but not blocking — implementers can navigate them with sensible defaults if S1-S3 are resolved.

Approximate re-pass effort: 30-60 minutes (one architect pass touching Contract C only; manifest doesn't need changes; A/B/D contracts are clean). After re-pass, this review should re-run to verify the fixes; expected verdict APPROVED.

---

## Appendix — Re-pass (v2) — 2026-06-01

**Verdict:** APPROVED-after-fix
**Re-pass actual effort:** ~25 minutes
**Files touched:** `contracts/C-AudiobookSessionPresenter-and-Migration.md` (full rewrite), `contracts/D-AppTabHost-MiniPlayer-and-FullCover.md` (small A3 clarification), `manifest.yaml` (verdict block + `findings_addressed`), this file (appendix).

### Significant findings — resolutions

**S1 — APPROVED via develop-base pinning (NOT rebased on fix branch).** Contract C now pins all line refs to develop's ACTUAL state, verified via re-greps:

- `stopPlayback(dismissPhoneUI: Bool = true) async` at develop line 509 (OLD signature; NO `persistFinalPosition` parameter — that's on the parallel fix branch).
- `dismissPlayerOnPhone(bookId:)` at develop lines 560-566 with the `coordinator.removeAudioModel + coordinator.popToRoot` pair.
- `presentCoverArtAndNavigation(for:loaded:)` at develop line 633; the `coordinator.storeAudioModel + pushAudioRoute` block at lines 647-654.
- `#if LCP (decryptor as? LCPAudiobooks)?.releaseResources()` at develop lines 532-534 — the ONLY LCP-specific code in the file on develop. The §7.5 "LCP-streaming-gate skip" concept from the design doc was numbered against the parallel fix branch; on develop there is no separate streaming-gate skip — the readiness gate (`awaitReadinessAndIssueFirstPlay` at line 786) is generic across LCP and OpenAccess.
- Off-limits zones expanded to explicitly enumerate `awaitReadinessAndIssueFirstPlay` (line 786), the readiness Task at lines 689-699, the probe factory defaults at lines 232-238, and the `#if LCP` block at lines 532-534. Module C may not touch ANY of these.

**Why not rebase / cherry-pick:** the fix branch `fix/3.2.0-audiobook-reborrow-position-and-lcp-gate` (`fd4378d95`) is in-flight in a parallel session and is NOT on develop yet. The swarm targets develop. Pinning to develop is structurally correct branching hygiene; rebasing later (if the fix branch merges first) is mechanical. The architect review v1 itself listed this as an acceptable alternative ("OR (lower-cost): cherry-pick `fd4378d95`"), so this is a sanctioned path.

**S2 — APPROVED via existing-file extension.** `PalaceTests/CarPlay/CarPlayAudiobookBridgeTests.swift` does not exist on develop (re-verified via `ls`). The canonical CarPlay test home is `PalaceTests/CarPlay/CarPlayTests.swift` with 7 existing XCTest classes (re-verified via `grep -rn "class .*Tests:"`). Contract C now directs the implementer to add a NEW XCTest class `CarPlayAudiobookBridgePresenterMigrationTests: XCTestCase` to the existing file (hosts the migration's tests 7-8), avoiding a phantom-file ref. Verification criterion 13 `-only-testing:` selectors updated to the real class names.

**S3 — APPROVED via AppContainer test-seam addition to Contract C scope.** Contract C now adds:
- `_audiobookSessionPresenterOverride: AudiobookSessionPresenter?` field (mirrors `_signInModalSheetPresenterOverride` at AppContainer line 44).
- `withAudiobookSessionPresenter(_:)` modifier (mirrors `withSignInModalSheetPresenter(_:)` at lines 92-114).
- `audiobookSessionPresenterOverride: AudiobookSessionPresenter? = nil` defaulted-nil init param (mirrors `signInModalSheetPresenterOverride: SignInModalSheetPresenter? = nil` at line 196).
- Updated `withSignInModalSheetPresenter(_:)` to propagate `audiobookSessionPresenterOverride` so chaining both modifiers preserves both overrides.

Estimated LOC bumped 250-400 → 275-425. Existing `AppContainerTests.swift` call sites (lines 40-59, 78-97) continue to compile because the new init param is defaulted-nil. Module D's tests 12-13 now have a clean injection seam.

### Advisory findings — resolutions

**A1 — APPROVED.** Contract C now explicitly documents the spy strategy for `AudiobookSessionManagerPresenterMigrationTests`:
- **Path 1 (spy presenter)** for tests 1, 5, 6 — inject via `audiobookSessionPresenterProvider` closure; assert spy received the expected calls. End-state assertion is sufficient because the legacy coordinator calls become unreachable post-migration.
- **Path 2 (live coordinator, observable-state)** for tests 2, 3, 4 — build a real `NavigationCoordinator()` + `NavigationCoordinatorHub()` (no-arg inits available, verified at `AppContainerTests.swift` lines 55, 93), drive the migrated code path, then assert on observable state: `coordinator.path.isEmpty == true`, `coordinator.audioModelById[bookId] == nil`, `coordinator.path.last` unchanged after dismiss. This proves the coordinator was NOT touched without needing a spy seam that doesn't exist.

Tests 2, 3, 4 reworded to use Path 2 (renamed: `testOpenAudiobook_firstOpen_doesNotPushAudioRouteOnRealCoordinator`, `testStopPlayback_doesNotLeaveAudioModelInCoordinatorCache`, `testStopPlayback_doesNotPopRealCoordinatorPath`). Each name embeds an explicit assertion about coordinator observable state, so `check-test-name-vs-body.py` will require the body to drive a real coordinator (not a spy).

**A2 — APPROVED.** Verification criterion 14 now cites `PalaceTests/LCP/` (re-verified via `ls`: `LCPAudiobooksTests.swift`, `LCPLibraryServiceTests.swift`, `LCPPassphraseReadinessTests.swift`, `LCPSessionOrphaningTests.swift`). Implementer runs `LCPAudiobooksTests` + `LCPSessionOrphaningTests` (the latter covers the stale-LCP-Publication race that the `#if LCP` block at lines 532-534 protects).

**A3 — APPROVED.** Contract D's NavigationHostView integration paragraph now explicitly says the modifier MUST wrap each rendered reader sub-branch (both EPUB sub-branches inside `.epub` case, all three PDF sub-branches inside `.pdf` case), NOT the case label. `EmptyView` fallback sub-branches do NOT need the modifier (no reader → suppression unnecessary). Verification grep floor of 3 remains (catches missing-an-entire-case); thorough per-sub-branch application yields 5-6 hits — both are accepted; the floor only catches "missed an entire case."

### Re-verification greps (run during re-pass)

```
# develop-base line refs (S1):
sed -n '509p' Palace/Audiobooks/AudiobookSessionManager.swift
  → `public func stopPlayback(dismissPhoneUI: Bool = true) async {`  ✓ matches Contract C

sed -n '560,566p' Palace/Audiobooks/AudiobookSessionManager.swift
  → `private func dismissPlayerOnPhone(bookId: String) {` + `coordinator.removeAudioModel` + `coordinator.popToRoot()`  ✓

sed -n '647,654p' Palace/Audiobooks/AudiobookSessionManager.swift
  → coordinator.storeAudioModel + coordinator.pushAudioRoute block  ✓

sed -n '532,534p' Palace/Audiobooks/AudiobookSessionManager.swift
  → `#if LCP` / `(decryptor as? LCPAudiobooks)?.releaseResources()` / `#endif`  ✓

sed -n '786p' Palace/Audiobooks/AudiobookSessionManager.swift
  → `internal func awaitReadinessAndIssueFirstPlay(`  ✓

sed -n '197,206p' Palace/CarPlay/CarPlayAudiobookBridge.swift
  → `dismissBookOnPhone` + Task + `coordinator.removeAudioModel + popToRoot`  ✓

# Test home paths (S2, A2):
ls PalaceTests/CarPlay/
  → CarPlayAuthHelperReadinessTests.swift, CarPlayTests.swift (no CarPlayAudiobookBridgeTests.swift)  ✓
ls PalaceTests/LCP/
  → LCPAudiobooksTests.swift, LCPLibraryServiceTests.swift, LCPPassphraseReadinessTests.swift, LCPPDFAcquisitionPredicateTests.swift, LCPSessionOrphaningTests.swift, LicensesServiceTests.swift  ✓

# AppContainer test-seam precedent (S3):
grep -n "_signInModalSheetPresenterOverride\|withSignInModalSheetPresenter\|signInModalSheetPresenterOverride:" Palace/AppInfrastructure/AppContainer.swift
  → field decl line 44, modifier line 92, init param line 196, init body assign line 216  ✓ — mirrored 1:1 in Contract C scope

# NavigationCoordinator spy seam (A1):
grep -n "final class NavigationCoordinator\b" Palace/AppInfrastructure/NavigationCoordinator.swift
  → line 52: `final class NavigationCoordinator: ObservableObject {`  ✓ — confirms no protocol, off-limits to extract one
grep -n "NavigationCoordinator()\|NavigationCoordinatorHub()" PalaceTests/AppInfrastructure/AppContainerTests.swift
  → lines 55, 93: both no-arg inits already used in tests  ✓ — Path 2 (live coordinator) is structurally available
```

### Verdict

**APPROVED-after-fix.** Manifest verdict updated to `APPROVED-after-fix`. Orchestrator may proceed to Phase 1b (commit scaffold) and Phase 3 (dispatch implementers) without re-running the reviewer. If the orchestrator prefers a fresh review-v2 pass for additional assurance, it can be triggered cheaply (the re-pass touched only Contract C + small Contract D edit + manifest verdict block).

Approximate dispatch readiness: all four contracts (A, B, C, D) are now pinned to develop's actual state with corrected file paths, corrected line refs, and a working test-seam precedent for cross-module Module D dependencies.

