# Module C — AudiobookSessionPresenter + pushAudioRoute migration (P3 + P4 — Audiobooks side)

**Risk:** critical_path — touches `Palace/Audiobooks/AudiobookSessionManager.swift` (audiobook hoist, F-011 readiness gate, CarPlay bridge contract, PP-3783 back-stack semantics)
**Reviewers required:** architect, qa_test, clean_code, blast_radius (CarPlay bridge implications)
**Estimated LOC:** 275–425 prod + 400–600 tests
**Depends on:** none — can run in parallel with A
**Blocks:** D (consumes `AudiobookSessionPresenter` for mini-player + root fullScreenCover; consumes `withAudiobookSessionPresenter(_:)` test seam for D's tests 12-13)
**Phase coverage:** §6.2 (A1 architecture) + §6.4 (data flow) + §7.2 (CarPlay) + §7.4 (first-open readiness) + §7.5 (LCP) + §8 P3 + §8 P4 (Audiobooks half) from `docs/architecture/in-app-navigation-during-playback.md`

**Base branch note:** This contract is written against the swarm scaffold at `0f245fe2f` (on top of `f9b09b18f` = develop tip). The parallel-session fix branch `fix/3.2.0-audiobook-reborrow-position-and-lcp-gate` (`fd4378d95`) is NOT on develop yet — its `stopPlayback(dismissPhoneUI:persistFinalPosition:)` signature, eviction-marker semantics, and renumbered LCP-streaming code do **not** exist in this contract's base. All line refs and signatures below are pinned to develop's ACTUAL state (verified by greps below). When/if the fix branch merges to develop ahead of this swarm, the orchestrator rebases the scaffold and the line refs shift mechanically — no contract logic changes.

## Scope summary

1. Create `AudiobookSessionPresenter` (`@MainActor ObservableObject`) — the root-level "what's playing right now" surface. Exposes `hasActiveSession: Bool`, `playbackModel: AudiobookPlaybackModel?`, `currentBook: TPPBook?`, `isPlayerExpanded: Bool`, `isReaderActive: Bool`. Driven by subscribing to `AudiobookSessionManaging.playbackStatePublisher` + bridging `currentBook` / `playbackModel`.

2. Migrate `AudiobookSessionManager` off `coordinator.pushAudioRoute(route)`. After this contract lands, `presentCoverArtAndNavigation(for:loaded:)` (develop line 633) MUST instead drive the presenter (set `playbackModel`, request `isPlayerExpanded = true` on first-open per §7.4). The current `coordinator.storeAudioModel(...)` + `pushAudioRoute(...)` block (develop lines 647-654) disappears.

3. Preserve PP-3783 back-stack semantics — but the semantics move from `NavigationCoordinator.pushAudioRoute` (per-tab nav stack) to the presenter (root-level expand/minimize). Specifically: opening audiobook B while audiobook A is active MUST replace the active session (`stopPlayback(dismissPhoneUI:)` already runs first in `openAudiobook`); the presenter's `playbackModel` switches to B. Minimize MUST return to whatever the user was looking at (tab/route preserved across the cover). NOTE: `stopPlayback` on this base has signature `stopPlayback(dismissPhoneUI: Bool = true) async` (develop line 509) — the OLD signature. Do NOT add the `persistFinalPosition:` parameter introduced on the parallel fix branch; preserve develop's signature exactly.

4. Preserve F-011 first-open behavior (§7.4) — on first-open via `openAudiobook(_, startPlaying: true)`, the presenter sets `isPlayerExpanded = true` so the cover art + loading state are visible during the readiness-gate wait. On resume from the mini-player / `MPNowPlayingInfoCenter`, `isPlayerExpanded` is NOT forced — caller decides. The readiness gate itself (`awaitReadinessAndIssueFirstPlay`, develop line 786) is OFF-LIMITS — Module C must NOT modify the gate, the probe factory wiring (lines 232-238), or the `Task { @MainActor in ... }` block at lines 689-699. The gate is the F-011 fix; touching it risks the bug. Module C only adds a presenter-state push BEFORE the Task block.

5. Wire `AppContainer.audiobookSessionPresenter` — process-wide instance, cached the same way `audiobookSession` is (develop AppContainer line 148-154). Consumers (`AppTabHostView` in Module D, future expand call sites) read it from the container.

6. **Add `withAudiobookSessionPresenter(_:)` test-seam modifier** to AppContainer, mirroring the existing `withSignInModalSheetPresenter(_:)` precedent (AppContainer lines 33-114). This unblocks Module D's tests 12-13 which inject a spy presenter via the container. Without this seam, D would either need its own deferral path or work around by editing AppContainer (out of scope for D).

## Public surface — new types

### `AudiobookSessionPresenter`

File: `Palace/Audiobooks/AudiobookSessionPresenter.swift` (NEW).

```swift
import Combine
import Foundation
import PalaceAudiobookToolkit
import SwiftUI

@MainActor
public final class AudiobookSessionPresenter: ObservableObject {
    /// True when there is an active audiobook session (loading, playing, or
    /// paused — anything where the mini-player should be visible). Derived
    /// from `AudiobookSessionState.isActive`.
    @Published public private(set) var hasActiveSession: Bool = false

    /// The playback model for the active session, mirrored from the session
    /// manager. The mini-player + full player views observe this for chrome
    /// updates (title, cover, play/pause).
    @Published public private(set) var playbackModel: AudiobookPlaybackModel?

    /// The currently bound book; mirrors `AudiobookSessionManaging.currentBook`.
    @Published public private(set) var currentBook: TPPBook?

    /// Drives the root-level full-player fullScreenCover. View code binds to
    /// this and shows / hides the cover accordingly.
    @Published public var isPlayerExpanded: Bool = false

    /// View-driven flag: NavigationHostView's `.epub` / `.pdf` /
    /// `presentedEPUBSample` route cases flip this on entry / off on exit.
    /// The mini-player view conditions its visibility on `!isReaderActive`
    /// (per §7.3 Option α).
    @Published public var isReaderActive: Bool = false

    public init(sessionManager: AudiobookSessionManaging)

    /// Called by `AudiobookSessionManager` on first-open (post-bind) to
    /// expand the player so cover art + loading state are visible during
    /// the readiness-gate wait. Per §7.4.
    public func presentOnFirstOpen()

    /// Called by tap-on-mini-player. Sets `isPlayerExpanded = true`.
    public func expand()

    /// Called by swipe-down-on-full-player (Module D adds the gesture). Sets
    /// `isPlayerExpanded = false`.
    public func minimize()
}
```

### `AppContainer` addition (2 changes)

File: `Palace/AppInfrastructure/AppContainer.swift` (MODIFY).

**Change 1 — cached process-wide presenter** (mirrors `audiobookSession` at develop lines 148-154):

```swift
@MainActor
var audiobookSessionPresenter: AudiobookSessionPresenter {
    if let override = _audiobookSessionPresenterOverride { return override }
    if let cached = AppContainer._audiobookSessionPresenter { return cached }
    let presenter = AudiobookSessionPresenter(sessionManager: self.audiobookSession)
    AppContainer._audiobookSessionPresenter = presenter
    return presenter
}

@MainActor private static var _audiobookSessionPresenter: AudiobookSessionPresenter?
```

**Change 2 — `withAudiobookSessionPresenter(_:)` test-seam modifier** (mirrors `withSignInModalSheetPresenter(_:)` at develop AppContainer lines 33-114). This is REQUIRED by Module D for tests 12-13 (S3 fix from architect review v1).

Add the override field:

```swift
private let _audiobookSessionPresenterOverride: AudiobookSessionPresenter?
```

Extend the `init(...)` parameter list with a defaulted-nil override (mirrors `signInModalSheetPresenterOverride: SignInModalSheetPresenter? = nil` at develop line 196). Extend the `withSignInModalSheetPresenter(_:)` rebuild pattern with a parallel `withAudiobookSessionPresenter(_:)` that passes ALL existing fields plus `audiobookSessionPresenterOverride: presenter`:

```swift
@MainActor
func withAudiobookSessionPresenter(_ presenter: AudiobookSessionPresenter) -> AppContainer {
    return AppContainer(
        bookRegistry: self.bookRegistry,
        networkExecutor: self.networkExecutor,
        // ... all 16 other existing init params unchanged ...
        signInModalSheetPresenterOverride: self._signInModalSheetPresenterOverride,
        audiobookSessionPresenterOverride: presenter
    )
}
```

The pattern is mechanical — both override fields propagate through every modifier so chaining `.withSignInModalSheetPresenter(spy1).withAudiobookSessionPresenter(spy2)` works. Update `withSignInModalSheetPresenter(_:)` (develop line 92-114) to pass `audiobookSessionPresenterOverride: self._audiobookSessionPresenterOverride` as well, so it doesn't lose any presenter override the caller already set.

No other AppContainer surface change. Production callers read via `AppContainer.production().audiobookSessionPresenter`; the override is `nil` by default. Tests use `.withAudiobookSessionPresenter(spy)` exactly like `.withSignInModalSheetPresenter(spy)`. Cost ~25 LOC.

### `AudiobookSessionManager` migration

File: `Palace/Audiobooks/AudiobookSessionManager.swift` (MODIFY).

Replace `presentCoverArtAndNavigation` body's `coordinator.storeAudioModel + coordinator.pushAudioRoute` block (develop lines 647-654) with a presenter call:

```swift
// BEFORE (develop lines 647-654 — REMOVE the coordinator block):
let route = BookRoute(id: book.identifier)
if let coordinator = navigationCoordinatorHubProvider().coordinator {
    Log.debug(#file, "Presenting audiobook player route for \(book.identifier)")
    coordinator.storeAudioModel(loaded.playbackModel, forBookId: route.id)
    coordinator.pushAudioRoute(route)
} else {
    Log.info(#file, "No navigation coordinator (CarPlay background launch?) — playback will start without phone UI")
}

// AFTER (new — REPLACE with presenter dispatch):
let presenter = audiobookSessionPresenterProvider()
presenter.presentOnFirstOpen()
```

Add a new injected provider closure (mirrors `navigationCoordinatorHubProvider`'s pattern at develop lines 161 / 197 / 207 / 231 / 246):

```swift
private let audiobookSessionPresenterProvider: () -> AudiobookSessionPresenter
```

Wire through the `init(appContainer:...)` convenience init (develop lines 227-251) with a default `{ AppContainer.production().audiobookSessionPresenter }`. Tests pass a closure returning a spy presenter via the manager's own DI seam — they do NOT need to go through AppContainer for the manager-side tests (the `withAudiobookSessionPresenter` modifier is for D's view-level tests, not C's manager-level tests).

`dismissPlayerOnPhone(bookId:)` (develop lines 560-566) currently calls `coordinator.removeAudioModel` + `coordinator.popToRoot`. After migration this becomes a presenter call: clear `playbackModel`, drop `currentBook`, set `hasActiveSession = false`, set `isPlayerExpanded = false`. The `coordinator.removeAudioModel` call MUST be removed — the audio model is now owned by the presenter, not the coordinator. The `coordinator.popToRoot` call MUST be removed too — there is no audio route on the nav stack after migration. NavigationCoordinator's `audioModelById` cache + `pushAudioRoute` / `clearAudioRoutes` / `isTopRouteAudio` become unused; this contract does NOT delete them (legacy compat per §6.2 point 3 — Module D + a follow-up swarm removes them after the rest of the migration is verified).

### `CarPlayAudiobookBridge.dismissBookOnPhone()` (develop lines 197-206) update

File: `Palace/CarPlay/CarPlayAudiobookBridge.swift` (MODIFY).

Currently calls `coordinator.removeAudioModel + coordinator.popToRoot`. After migration, this becomes a presenter call:

```swift
func dismissBookOnPhone() {
    Task { @MainActor in
        let presenter = AppContainer.production().audiobookSessionPresenter
        presenter.minimize()
        // Optionally clear visible state if a future surface needs it; for
        // now minimize() is the correct semantic ("don't show full player").
    }
}
```

This preserves the user-visible behavior: CarPlay disconnect should NOT kill phone playback, only dismiss the full-screen player UI. The session itself remains active (mini-player still visible on the phone — that's the whole P3 win).

## Behavior contracts (test these — required)

### `AudiobookSessionPresenterTests` in `PalaceTests/Audiobooks/`

1. **`testHasActiveSession_isFalseWhenSessionIdle`** — spy session in `.idle` → `hasActiveSession == false`.

2. **`testHasActiveSession_becomesTrueWhenSessionTransitionsToLoading`** — spy session emits `.loading(bookId:)` via `playbackStatePublisher` → `hasActiveSession == true`. Mutates: dropping the subscription fails.

3. **`testHasActiveSession_becomesTrueWhenSessionTransitionsToPlaying`** — same as above for `.playing(bookId:)`.

4. **`testHasActiveSession_becomesFalseWhenSessionReturnsToIdle`** — was true, then session goes `.idle` → false again. Mutates: not updating on the second emission fails.

5. **`testPresentOnFirstOpen_setsIsPlayerExpandedTrue`** — pre: `isPlayerExpanded == false`. Call `presentOnFirstOpen()`. Post: `isPlayerExpanded == true`. Mutates: removing the assignment fails.

6. **`testExpand_setsIsPlayerExpandedTrue`** — pre: false. Call `expand()`. Post: true.

7. **`testMinimize_setsIsPlayerExpandedFalse`** — pre: true. Call `minimize()`. Post: false.

8. **`testIsReaderActive_isPubliclyMutable`** — set `isReaderActive = true`, then false. Both transitions persist (the published value is what view code reads).

### `AudiobookSessionManagerPresenterMigrationTests` in `PalaceTests/Audiobooks/`

These verify the migration from `pushAudioRoute` to `presenter.presentOnFirstOpen()`. The existing `AudiobookSessionManagerTests` MUST still pass — this file ADDS coverage for the presenter seam without replacing existing tests.

**Spy strategy (A1 fix from architect review v1):** `NavigationCoordinator` is `final` (develop line 52) with no protocol extracted, and modifying it is on Module C's off-limits list. Implementer CANNOT spin a `MockNavigationCoordinator` subclass. The implementer has two viable assertion paths and MUST use both:

1. **Presenter spy** (primary) — inject a spy `AudiobookSessionPresenter` via the `audiobookSessionPresenterProvider` closure. Assert the spy received the expected calls (`presentOnFirstOpen()` / clear-state). This is the END-STATE assertion — the legacy coordinator calls become unreachable as a result of the contract change, so absence-of-side-effect on a presenter that recorded calls IS the proof.

2. **NavigationCoordinatorHub provider closure** (secondary) — the `navigationCoordinatorHubProvider` closure (develop line 161, 197, 207, 231, 246) is already a DI seam. Tests pass a closure that returns a hub whose `coordinator` property returns `nil`. With no coordinator available, any leaked `coordinator.pushAudioRoute(...)` call would be a structural impossibility (force-unwrapping nil would crash), so the test asserts "no crash" + "presenter received its call." Alternative: build a real `NavigationCoordinatorHub` + `NavigationCoordinator` (the `NavigationCoordinator()` and `NavigationCoordinatorHub()` no-arg inits are available; existing `AppContainerTests.swift` constructs both — develop lines 55, 93), drive the migrated `presentCoverArtAndNavigation` path, then ASSERT on the real coordinator's observable state: `coordinator.path.isEmpty == true` (no `.audio` route was pushed) and `coordinator.audioModelById[bookId] == nil` (no model was stored). Both of these properties exist on the live coordinator and are checkable post-call.

Implementer chooses path 1 (spy presenter) for tests 1, 5, 6 (presenter-side assertions). Implementer uses path 2 (live coordinator, observable-state assertions) for tests 2, 3, 4 (proving coordinator was NOT touched).

1. **`testOpenAudiobook_firstOpen_callsPresenterPresentOnFirstOpen`** — spy presenter via `audiobookSessionPresenterProvider`; full open of a downloaded mock audiobook → spy records `presentOnFirstOpen()` was called exactly once. Mutates: removing the call fails.

2. **`testOpenAudiobook_firstOpen_doesNotPushAudioRouteOnRealCoordinator`** — real `NavigationCoordinator` + `NavigationCoordinatorHub`; full open → `coordinator.path.isEmpty == true` (no `.audio` route on the nav stack). Mutates: leaving the legacy `pushAudioRoute` call in fails.

3. **`testStopPlayback_doesNotLeaveAudioModelInCoordinatorCache`** — real `NavigationCoordinator`; full open then `stopPlayback(dismissPhoneUI: true)` → `coordinator.audioModelById[bookId] == nil`. (Audio model now owned by presenter; coordinator no longer holds it.) Mutates: leaving the legacy `storeAudioModel` call in fails the open half; leaving `removeAudioModel` in fails the dismiss half. Either way the test catches drift in either direction.

4. **`testStopPlayback_doesNotPopRealCoordinatorPath`** — real coordinator with one non-audio route already pushed (e.g. `.bookDetail(BookRoute(id: "preexisting"))`); full open + `stopPlayback(dismissPhoneUI: true)` → coordinator's `path.last` still equals the pre-existing route (NOT popped to root). Mutates: leaving `coordinator.popToRoot()` in `dismissPlayerOnPhone` fails this — the pre-existing route would have been wiped.

5. **`testStopPlayback_clearsPresenterPlaybackModel`** — pre: presenter has a playback model (set by a prior open). Call `stopPlayback(dismissPhoneUI: true)`. Post: `presenter.playbackModel == nil`, `presenter.hasActiveSession == false`, `presenter.isPlayerExpanded == false`. (This is the new "dismiss phone UI" semantic.)

6. **`testOpenAudiobook_switchingAudiobooks_clearsPreviousPlaybackModel`** — open A; spy presenter records playback model for A. Open B (PP-3783 "switching books" scenario; `openAudiobook` internally calls `stopPlayback(dismissPhoneUI: false)` first per develop line 329). Spy records the model swap to B. (The "active session B" replaces A — this is the new presenter equivalent of the old `clearAudioRoutes`.)

### CarPlay regression contract — `PalaceTests/CarPlay/CarPlayTests.swift` (MODIFY)

**S2 fix from architect review v1:** The CarPlay test home on develop is `PalaceTests/CarPlay/CarPlayTests.swift` (verified by `ls PalaceTests/CarPlay/`). That file contains 7 XCTest classes: `CarPlayTests`, `CarPlayIntegrationTests`, `CarPlayOpenAppAlertTests`, `CarPlayLibraryRefreshTests`, `CarPlayNowPlayingTemplateTests`, `CarPlayChapterListTests`, `CarPlayPlaybackErrorTests`. `PalaceTests/CarPlay/CarPlayAudiobookBridgeTests.swift` does NOT exist on develop.

Implementer adds a NEW test class `CarPlayAudiobookBridgePresenterMigrationTests: XCTestCase` to `PalaceTests/CarPlay/CarPlayTests.swift` (existing file — extend it; don't add a sibling file unless coverage adds >100 LOC). This keeps CarPlay tests in the canonical home and avoids a phantom file ref. The new class hosts tests 7-8 below.

7. **`testCarPlayBridge_dismissBookOnPhone_callsPresenterMinimize`** — spy presenter exposed via `AppContainer.withAudiobookSessionPresenter(spy)` (the test seam this contract adds). Construct `CarPlayAudiobookBridge` with the test container. Call `bridge.dismissBookOnPhone()`. Spy records `minimize()` was called. Mutates: leaving the legacy `coordinator.removeAudioModel + popToRoot` calls in fails.

8. **`testCarPlayBridge_dismissBookOnPhone_doesNotKillSession`** — the existing session-manager state remains active (`session.state.isActive == true`). This locks in the "CarPlay disconnect doesn't stop playback" UX explicitly — was implicit before; now part of the contract.

### State-machine round-trip wiring (per CLAUDE.md wall-failure catalog)

9. **`testPresenter_expand_minimize_expandAgain_drivesIsPlayerExpandedCorrectly_acrossThreeTransitions`** — exercise the full lifecycle via the production seams (`expand()` → `minimize()` → `expand()`); assert `isPlayerExpanded` flips correctly each time. Body MUST do all three transitions (not just two) per CLAUDE.md DoD #3 multi-step-test-body check. The test name embeds "acrossThreeTransitions" so `check-test-name-vs-body.py` will require all three.

## Files in scope for this implementer

Production:
- `Palace/Audiobooks/AudiobookSessionPresenter.swift` (NEW, ~90 LOC)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (MODIFY — migrate `presentCoverArtAndNavigation` lines 633-655 + `dismissPlayerOnPhone` lines 560-566 + add `audiobookSessionPresenterProvider` closure to init at lines 197-216 + convenience init at lines 227-251)
- `Palace/CarPlay/CarPlayAudiobookBridge.swift` (MODIFY — `dismissBookOnPhone` lines 197-206 calls `presenter.minimize()` instead of coordinator)
- `Palace/AppInfrastructure/AppContainer.swift` (MODIFY — add `audiobookSessionPresenter` computed property + cached static + `_audiobookSessionPresenterOverride` field + `withAudiobookSessionPresenter(_:)` modifier + propagate override through existing `withSignInModalSheetPresenter(_:)`; extend `init(...)` signature with defaulted-nil `audiobookSessionPresenterOverride: AudiobookSessionPresenter? = nil`)

Tests:
- `PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift` (NEW)
- `PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift` (NEW)
- `PalaceTests/CarPlay/CarPlayTests.swift` (MODIFY — add `CarPlayAudiobookBridgePresenterMigrationTests` class with tests 7-8; preserve all existing classes)
- `PalaceTests/Audiobooks/AudiobookSessionManagerTests.swift` (READ-ONLY — must still pass)

Mocks:
- Add `SpyAudiobookSessionPresenter` to `PalaceTests/Mocks/` for migration tests. Spy should record calls (`presentOnFirstOpen`, `expand`, `minimize`) + expose mutable `@Published` properties for direct test inspection.

## Files OFF-LIMITS to this implementer

- `Palace/AppInfrastructure/AppTabHostView.swift`, `NavigationHostView.swift` — Module D.
- `Palace/AppInfrastructure/NavigationCoordinator.swift` — do NOT remove `pushAudioRoute` / `clearAudioRoutes` / `isTopRouteAudio` / `audioModelById` cache (legacy compat per §6.2 point 3; cleanup is a follow-up swarm after the rest is verified — see Wall-failure derived improvements). The class is `final` and HAS NO protocol; do not extract one in this contract.
- `Palace/CatalogUI/*`, `Palace/MyBooks/*` — Modules A / B.
- `Palace/Audiobooks/NowPlayingCoordinator.swift` — must NOT change (CarPlay lock-screen wiring, §7.2).
- `Palace/Audiobooks/PlaybackBootstrapper.swift` — must NOT change.
- `awaitReadinessAndIssueFirstPlay` (develop line 786) + the `Task { @MainActor in ... }` block at lines 689-699 + the probe factory defaults at lines 232-238 — F-011 fix surface, must not be touched. Module C's only addition near this code is calling `presenter.presentOnFirstOpen()` BEFORE the Task block (i.e. in `presentCoverArtAndNavigation` which is called at line 612, before `startPlaybackAndSyncPosition` at line 615).
- The `#if LCP` block at develop lines 532-534 (LCPAudiobooks.releaseResources) — must not be touched. This is the only LCP-specific code in this file on develop; preserve it byte-for-byte.

## AppContainer wiring (in this contract)

`AppContainer.audiobookSessionPresenter` computed property added. Lazy + cached the same way `audiobookSession` is. NEW: `_audiobookSessionPresenterOverride` field + `withAudiobookSessionPresenter(_:)` modifier added (S3 fix). The `init(...)` gets one new defaulted-nil parameter (`audiobookSessionPresenterOverride: AudiobookSessionPresenter? = nil`); existing call sites in `AppContainerTests.swift` (lines 40-59 and 78-97) continue to compile because the new param is defaulted.

Module D's tests 12-13 use the modifier:

```swift
let testContainer = AppContainer.production().withAudiobookSessionPresenter(spy)
// pass testContainer to AppTabHostView; spy receives observable state.
```

For Module C's own migration tests (`AudiobookSessionManagerPresenterMigrationTests`), the spy is injected via the manager's `audiobookSessionPresenterProvider` closure directly — no AppContainer modifier needed at that level.

## CarPlay smoke + LCP-streaming smoke gates

Per CLAUDE.md risk-driven rigor bar:

**CarPlay smoke (S2 fix):** Run the existing CarPlay test classes in `PalaceTests/CarPlay/CarPlayTests.swift` and `PalaceTests/CarPlay/CarPlayAuthHelperReadinessTests.swift`. Specific class selectors that exercise the bridge contract: `CarPlayTests`, `CarPlayIntegrationTests`, `CarPlayNowPlayingTemplateTests`, `CarPlayChapterListTests`, `CarPlayPlaybackErrorTests`. Paste pass-count tails.

**LCP-streaming smoke (A2 fix):** LCP tests live at `PalaceTests/LCP/` (verified: `LCPAudiobooksTests.swift`, `LCPLibraryServiceTests.swift`, `LCPPassphraseReadinessTests.swift`, `LCPSessionOrphaningTests.swift`). The §7.5 finding is "no regression to LCP-streaming-gate skip path." On develop's base, the only LCP-specific code in `AudiobookSessionManager.swift` is the `#if LCP` block at lines 532-534 (`(decryptor as? LCPAudiobooks)?.releaseResources()`) inside `stopPlayback`. There is NO `isLCPAudiobook` branching or LCP-aware gate-skip on this base — that lives on the parallel fix branch and is NOT in scope here. The "preservation invariant" reduces to: do not touch lines 532-534, do not touch `awaitReadinessAndIssueFirstPlay`, do not touch the readiness Task at 689-699. Run `LCPAudiobooksTests` + `LCPSessionOrphaningTests` (the latter covers the "stale LCP Publication" race that line 532 protects). Paste pass-count tails.

## F-011 first-open preservation

The test that locks in §7.4 behavior:

```
testOpenAudiobook_firstOpen_setsPresenterIsPlayerExpandedTrue_beforeReadinessGateCompletes
```

The implementer's modified `presentCoverArtAndNavigation` MUST call `presenter.presentOnFirstOpen()` synchronously, BEFORE the `Task { @MainActor in ... }` block at develop line 689 that drives the readiness gate. Since `presentCoverArtAndNavigation` is itself called from `bind()` at line 612 — which runs BEFORE `startPlaybackAndSyncPosition` at line 615 (the function that contains the Task block at line 689) — synchronous ordering is guaranteed structurally as long as the implementer keeps the call at the top of `presentCoverArtAndNavigation` (replacing the coordinator block at lines 647-654). The test asserts on the presenter state immediately after `bind()` returns (no awaiting). Mutates: moving `presentOnFirstOpen()` inside any `Task { @MainActor in ... }` block fails the test (presenter would remain collapsed until the async hop runs).

A second test:

```
testOpenAudiobook_resumeFromMiniPlayer_doesNOTForceIsPlayerExpanded
```

The `openAudiobook(_, startPlaying: true)` flow currently always calls `bind() → presentCoverArtAndNavigation` from a freshly-loaded session. For "resume from mini-player" — which after this contract becomes "user is already mid-session and taps the mini-player" — the entry point is `presenter.expand()`, not `openAudiobook`. This test asserts the wiring: starting a fresh open auto-expands; an `expand()` call from external (e.g. mini-player tap simulation) sets `isPlayerExpanded = true` directly. The two paths converge but the "first-open auto-expand" semantic is owned by `presentOnFirstOpen()`, not by `expand()`.

## Verification criteria (grep-able)

```bash
# 1. New presenter exists:
grep -c "public final class AudiobookSessionPresenter" Palace/Audiobooks/AudiobookSessionPresenter.swift   # >= 1
grep -c "var hasActiveSession\|var isPlayerExpanded\|var isReaderActive" Palace/Audiobooks/AudiobookSessionPresenter.swift   # >= 3

# 2. AppContainer wires the presenter (cache + test seam — both required):
grep -c "audiobookSessionPresenter" Palace/AppInfrastructure/AppContainer.swift   # >= 4 (computed property, static cache, override field, modifier — count includes the AudiobookSessionPresenter type ref so adjust if exact match needed)
grep -c "withAudiobookSessionPresenter" Palace/AppInfrastructure/AppContainer.swift   # >= 1
grep -c "_audiobookSessionPresenterOverride" Palace/AppInfrastructure/AppContainer.swift   # >= 2 (field decl + override consumer in computed property)

# 3. pushAudioRoute migration:
grep -c "pushAudioRoute\|coordinator.pushAudioRoute" Palace/Audiobooks/AudiobookSessionManager.swift   # 0 (after migration)
grep -c "presenter.presentOnFirstOpen\|audiobookSessionPresenterProvider" Palace/Audiobooks/AudiobookSessionManager.swift   # >= 2

# 4. coordinator.removeAudioModel + popToRoot removed from manager:
grep -c "coordinator.removeAudioModel\|coordinator.popToRoot" Palace/Audiobooks/AudiobookSessionManager.swift   # 0

# 5. CarPlay bridge migrated:
grep -c "coordinator.removeAudioModel\|coordinator.popToRoot" Palace/CarPlay/CarPlayAudiobookBridge.swift   # 0
grep -c "presenter.minimize\|audiobookSessionPresenter" Palace/CarPlay/CarPlayAudiobookBridge.swift   # >= 1

# 6. SUT instantiation in tests (DoD #1):
grep -c "AudiobookSessionPresenter(" PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift   # >= 1
grep -c "AudiobookSessionManager\b" PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift   # >= 1
python3 scripts/check-test-name-vs-body.py PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/CarPlay/CarPlayTests.swift   # exit 0 (covers the new presenter-migration class)

# 7. Round-trip test exists (CLAUDE.md state-machine wiring):
grep -in "expand_minimize_expandAgain\|acrossThreeTransitions" PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift   # >= 1

# 8. F-011 preservation test exists:
grep -in "firstOpen_setsPresenterIsPlayerExpandedTrue\|firstOpen.*expand" PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift   # >= 1

# 9. PP-3783 switching-audiobooks test exists:
grep -in "switchingAudiobooks\|switching_audiobooks\|switchingBooks_clearsPrevious" PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift   # >= 1

# 10. Mutation pass — REQUIRED diff-scoped ≥50%, ideally 100% on touched lines (DoD #5):
python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookSessionPresenter.swift --tests AudiobookSessionPresenterTests --diff-only
python3 scripts/palace_mutate.py --file Palace/Audiobooks/AudiobookSessionManager.swift --tests AudiobookSessionManagerPresenterMigrationTests --diff-only

# 11. Blast-radius (DoD #9):
python3 scripts/check-blast-radius.py --quiet   # exit 0

# 12. Adjacency staleness (DoD #10) — we are NOT removing pushAudioRoute, but we ARE removing calls to it:
python3 scripts/check-adjacency-staleness.py --quiet   # warn-only; paste output

# 13. CarPlay smoke regression — actual classes that exist on develop (S2 fix):
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/CarPlayTests \
  -only-testing:PalaceTests/CarPlayIntegrationTests \
  -only-testing:PalaceTests/CarPlayNowPlayingTemplateTests \
  -only-testing:PalaceTests/CarPlayChapterListTests \
  -only-testing:PalaceTests/CarPlayPlaybackErrorTests \
  -only-testing:PalaceTests/CarPlayAudiobookBridgePresenterMigrationTests \
  test 2>&1 | tail -30

# 14. LCP streaming smoke — actual class home on develop (A2 fix):
ls PalaceTests/LCP/ 2>&1 | head -10   # expected: LCPAudiobooksTests.swift, LCPLibraryServiceTests.swift, LCPPassphraseReadinessTests.swift, LCPSessionOrphaningTests.swift
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/LCPAudiobooksTests \
  -only-testing:PalaceTests/LCPSessionOrphaningTests \
  test 2>&1 | tail -20
```

## pbxproj wiring

```bash
ruby scripts/pbxproj_add_swift.rb Palace/Audiobooks/AudiobookSessionPresenter.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift
```

`AudiobookSessionManager.swift`, `CarPlayAudiobookBridge.swift`, `AppContainer.swift`, and `PalaceTests/CarPlay/CarPlayTests.swift` already exist in the relevant targets — modify in place; no pbxproj change.

## Scope-deferral protocol

If the `coordinator.popToRoot()` removal in `stopPlayback`'s phone-side dismiss path proves entangled with a per-tab back-stack that has user-visible state we need to preserve (e.g. the user was deep in a book-detail subview when CarPlay dismissed), STOP and propose:
- (a) keep `coordinator.popToRoot()` as a no-op pass-through with a TODO ticket; defer the cleanup;
- (b) replace it with a more nuanced presenter-driven path-truncation (e.g. drop only `.audio` route entries — but those are gone after migration, so this would be a no-op);
- (c) extend scope to migrate the dismiss path properly.

Do NOT silently leave both code paths active.

## Risk classification

**Critical_path.** Touches `Palace/Audiobooks/AudiobookSessionManager.swift` (audiobook playback, F-011 readiness gate fix, CarPlay session contract, PP-3783 back-stack semantics). Mutation pass is MANDATORY (≥50% diff-scoped). CarPlay smoke + LCP streaming smoke MUST be run.

This contract preserves four load-bearing invariants:
1. **F-011 first-open expand** — cover art + loading state visible during readiness gate (§7.4). Tested via `testOpenAudiobook_firstOpen_setsPresenterIsPlayerExpandedTrue_beforeReadinessGateCompletes`.
2. **CarPlay publisher contract unchanged** — `playbackStatePublisher`, `chapterUpdatePublisher`, `errorPublisher` on `AudiobookSessionManager` keep the same shape. `CarPlayAudiobookBridge.setupSubscriptions()` does not need to change. Tested via existing `CarPlayTests` + `CarPlayNowPlayingTemplateTests` + `CarPlayPlaybackErrorTests` regression suite.
3. **PP-3783 "switching books replaces, opening from detail stacks"** — the new presenter equivalent: opening B while A active swaps `playbackModel`; opening A from book-detail does not push a per-tab route at all (root presenter is the only UI surface), so "back" returns to whatever was on the nav stack before the open began. Tested via `testOpenAudiobook_switchingAudiobooks_clearsPreviousPlaybackModel`.
4. **§7.5 LCP-streaming invariant (develop-base interpretation)** — `#if LCP (decryptor as? LCPAudiobooks)?.releaseResources()` at develop lines 532-534 must not be touched. The "LCP-streaming-gate skip" concept from the design doc was numbered against the parallel fix branch; on develop there is no separate streaming-gate skip — the readiness gate is generic across LCP and OpenAccess. Preservation here means: do not modify lines 532-534, do not modify `awaitReadinessAndIssueFirstPlay` (develop line 786), do not modify the readiness Task at lines 689-699, do not modify the probe factory defaults at lines 232-238. Tested by running `LCPAudiobooksTests` + `LCPSessionOrphaningTests` and showing no regression vs. baseline.
