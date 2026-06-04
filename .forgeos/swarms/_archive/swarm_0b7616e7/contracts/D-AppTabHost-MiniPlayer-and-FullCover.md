# Module D — AppTabHostView mini-player + root fullScreenCover + reader suppression hook (P3 + P4 — AppInfrastructure side)

**Risk:** critical_path — touches the app's root presentation surface; mini-player is the user-visible payoff of the whole feature; reader-route suppression (§7.3 Option α) is the failure mode if wrong (mini-player flashing over reader)
**Reviewers required:** architect, qa_test, clean_code, blast_radius (root view hierarchy + safeAreaInset)
**Estimated LOC:** 200–350 prod + 250–400 tests
**Depends on:** C (consumes `AudiobookSessionPresenter` from `AppContainer.audiobookSessionPresenter`)
**Blocks:** none
**Phase coverage:** §6.2 (A1 mini-player + root fullScreenCover) + §7.1 (Accessibility) + §7.3 (Reader suppression) + §7.4 (First-open expand) + §8 P3 + §8 P4 (AppInfrastructure half) from `docs/architecture/in-app-navigation-during-playback.md`

## Scope summary

1. Create `AudiobookMiniPlayerView` (SwiftUI) — bottom-bar chrome rendered via `safeAreaInset(edge: .bottom)` on `AppTabHostView`'s `TabView`. Tap = expand to full player. Visible when `presenter.hasActiveSession && !presenter.isReaderActive`.

2. Create `AudiobookFullPlayerCoverContainer` (SwiftUI) — root-level `fullScreenCover(isPresented: $presenter.isPlayerExpanded)`. Hosts the existing `AudiobookPlayerView` and adds a custom swipe-down gesture that flips `presenter.minimize()` (§11 row 5: "custom swipe-down to match Audible's full-takeover aesthetic"). Reduce-motion path skips the slide-out animation.

3. Wire the reader-suppression hook in `NavigationHostView` — for `.epub`, `.pdf`, and `presentedEPUBSample` cases set `presenter.isReaderActive = true` on entry, `false` on exit. Use a `.onAppear` / `.onDisappear` pair OR a dedicated `IsReaderActiveTrackingModifier` (preferred — single place to maintain).

4. Remove the navigation-destination case for `.audio(BookRoute)` in `NavigationHostView` (lines 104-113) — after Module C lands `pushAudioRoute` is no longer called, so the destination case becomes unreachable. **Keep `AppRoute.audio` enum case** (NavigationCoordinator.swift:14) and the coordinator's `pushAudioRoute` method for legacy compat per §6.2 point 3; only the NavigationHostView destination renderer is dead.

## Public surface — new types

### `AudiobookMiniPlayerView`

File: `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` (NEW — lives under AppInfrastructure because it is part of the root host; nothing in `Palace/Audiobooks/` depends on it).

```swift
import SwiftUI
import PalaceAudiobookToolkit

@MainActor
struct AudiobookMiniPlayerView: View {
    @ObservedObject var presenter: AudiobookSessionPresenter

    var body: some View {
        if presenter.hasActiveSession && !presenter.isReaderActive {
            miniPlayerChrome
        } else {
            EmptyView()
        }
    }

    private var miniPlayerChrome: some View { ... /* cover + title + play/pause */ }
}
```

Accessibility (§7.1) — REQUIRED:
- `.accessibilityLabel("Now playing: <title> by <author>, \(state). Double-tap to expand.")`
- Play/pause button MUST have `.accessibilityLabel(Strings.Audiobook.play)` / `.accessibilityLabel(Strings.Audiobook.pause)` from the existing strings catalog.
- VoiceOver focus moves into the expanded player on open and returns to the mini-player on minimize. Use `UIAccessibility.post(notification: .screenChanged, argument: ...)` in `.onChange(of: presenter.isPlayerExpanded)`.
- Dynamic Type: chrome MUST reflow at AX1–AX5; truncate title before hiding controls.

### `AudiobookFullPlayerCoverContainer`

File: `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` (NEW).

```swift
import SwiftUI
import PalaceAudiobookToolkit

@MainActor
struct AudiobookFullPlayerCoverContainer: View {
    @ObservedObject var presenter: AudiobookSessionPresenter

    var body: some View {
        if let model = presenter.playbackModel {
            AudiobookPlayerView(model: model)
                .gesture(swipeDownToMinimize)
        } else {
            EmptyView()
        }
    }

    private var swipeDownToMinimize: some Gesture {
        DragGesture(minimumDistance: 50, coordinateSpace: .local)
            .onEnded { value in
                // Only minimize on downward swipe past threshold; ignore upward / horizontal.
                if value.translation.height > 100 && abs(value.translation.width) < 60 {
                    if UIAccessibility.isReduceMotionEnabled {
                        presenter.minimize()
                    } else {
                        withAnimation(.easeInOut) { presenter.minimize() }
                    }
                }
            }
    }
}
```

### `IsReaderActiveTrackingModifier`

File: `Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift` (NEW).

```swift
import SwiftUI

struct IsReaderActiveTrackingModifier: ViewModifier {
    let presenter: AudiobookSessionPresenter
    func body(content: Content) -> some View {
        content
            .onAppear { presenter.isReaderActive = true }
            .onDisappear { presenter.isReaderActive = false }
    }
}

extension View {
    func tracksReaderActive(_ presenter: AudiobookSessionPresenter) -> some View {
        modifier(IsReaderActiveTrackingModifier(presenter: presenter))
    }
}
```

### `AppTabHostView` integration

File: `Palace/AppInfrastructure/AppTabHostView.swift` (MODIFY).

In `body`, ADD:

```swift
.safeAreaInset(edge: .bottom) {
    AudiobookMiniPlayerView(presenter: appContainer.audiobookSessionPresenter)
        .onTapGesture { appContainer.audiobookSessionPresenter.expand() }
}
.fullScreenCover(isPresented: Binding(
    get: { appContainer.audiobookSessionPresenter.isPlayerExpanded },
    set: { appContainer.audiobookSessionPresenter.isPlayerExpanded = $0 }
)) {
    AudiobookFullPlayerCoverContainer(presenter: appContainer.audiobookSessionPresenter)
}
```

The presenter is read from `appContainer` (already in scope). No new property on `AppTabHostView`.

### `NavigationHostView` integration

File: `Palace/AppInfrastructure/NavigationHostView.swift` (MODIFY).

For each reader case (`.epub`, `.pdf`, `presentedEPUBSample`), apply `.tracksReaderActive(appContainer.audiobookSessionPresenter)` to the rendered reader view. Pass the presenter via `@Environment(\.appContainer)` (already wired). Suppression engages on `.onAppear`, disengages on `.onDisappear` — the SwiftUI lifecycle for a navigation-destination route does fire `onAppear` reliably (validated by existing `.toolbar(.hidden, for: .tabBar)` directives that rely on the same lifecycle).

**A3 sub-branch coverage clarification (architect review v1):** The modifier MUST wrap each rendered reader sub-branch, NOT the `case` label. `.epub` has multiple sub-branches inside its case body (`if let pubData → EPUBReaderView`, `else if let vc → UIViewControllerWrapper`, `else → EmptyView`). `.pdf` has three (`if let pdfDoc → PalacePDFView`, `if let url → UIViewControllerWrapper`, `else → EmptyView`). Applying `.tracksReaderActive(...)` to the case label only would cover one branch and leak the mini-player on the other (the modifier's `.onAppear` fires for the case-level view, but the sub-branches `if let` open/close around their OWN render lifecycle). Apply the modifier to EACH non-EmptyView sub-branch (so both `EPUBReaderView` AND `UIViewControllerWrapper` get it inside `.epub`). The `EmptyView` fallback sub-branch does NOT need it (no reader → suppression unnecessary). Expected grep floor (verification criterion 3): `>= 3` is the structural minimum (one per case), but a thorough per-sub-branch application yields ~5-6 hits — both are accepted; the floor of 3 only catches "missed an entire case."

Remove the `.audio(let bookRoute)` case body (lines 104-113) — after Module C lands, this branch is unreachable from production code. Replace with `EmptyView()` or `fatalError("Legacy .audio route — should not be reached after presenter migration")` (DEBUG only). Per §6.2 point 3 the `AppRoute.audio` enum case stays; only the dead destination renderer goes.

## Behavior contracts (test these — required)

### `AudiobookMiniPlayerViewTests` in `PalaceTests/AppInfrastructure/`

1. **`testMiniPlayer_isHidden_whenHasActiveSessionFalse`** — `presenter.hasActiveSession == false` → rendered hierarchy is `EmptyView` (no chrome). Mutates: flipping the guard fails.

2. **`testMiniPlayer_isHidden_whenIsReaderActiveTrue`** — even with `hasActiveSession == true`, if `isReaderActive == true`, hidden. (§7.3 Option α — the load-bearing suppression.) Mutates: removing `&& !presenter.isReaderActive` fails.

3. **`testMiniPlayer_isVisible_whenSessionActiveAndReaderNotActive`** — both flags align with visibility → chrome rendered. (The happy path. With test 1 + 2 this fully pins the visibility predicate.)

4. **`testMiniPlayer_tapInvokesExpand`** — simulate tap → spy presenter records `expand()` call. Mutates: removing the gesture fails.

5. **`testMiniPlayer_hasAccessibilityLabel`** — assert `.accessibilityLabel` contains the book title + "double-tap to expand". (§7.1) Mutates: removing the label fails.

### `AudiobookFullPlayerCoverContainerTests` in `PalaceTests/AppInfrastructure/`

6. **`testFullPlayerCover_isEmptyWhenNoPlaybackModel`** — `presenter.playbackModel == nil` → rendered hierarchy is `EmptyView`. Locks in the safety guard against showing the cover with no model.

7. **`testFullPlayerCover_rendersAudiobookPlayerView_whenModelPresent`** — `presenter.playbackModel` non-nil → AudiobookPlayerView in the hierarchy.

8. **`testFullPlayerCover_swipeDownInvokesMinimize`** — simulate a downward drag past 100pt threshold → spy presenter records `minimize()`. Mutates: lowering the threshold fails the boundary test.

9. **`testFullPlayerCover_swipeUp_doesNotMinimize`** — simulate upward drag → spy records ZERO `minimize()` calls. (Boundary case — only downward drags trigger.)

### `IsReaderActiveTrackingModifierTests` in `PalaceTests/AppInfrastructure/`

10. **`testTracksReaderActive_setsTrueOnAppear`** — host a `Color.red.tracksReaderActive(presenter)` view; trigger onAppear (via ViewInspector OR by hosting in a UIHostingController and adding to a UIWindow). Post: `presenter.isReaderActive == true`. Mutates: removing `.onAppear` fails.

11. **`testTracksReaderActive_setsFalseOnDisappear`** — same setup; trigger onDisappear. Post: `presenter.isReaderActive == false`. Mutates: removing `.onDisappear` fails.

### `AppTabHostMiniPlayerIntegrationTests` in `PalaceTests/AppInfrastructure/`

12. **`testAppTabHost_safeAreaInsetContainsMiniPlayer`** — construct `AppTabHostView(appContainer: testContainer)` with a `withAudiobookSessionPresenter(spy)` test container; assert the rendered hierarchy contains an `AudiobookMiniPlayerView`. (May require ViewInspector or a thin host harness.)

13. **`testAppTabHost_fullScreenCoverBindsToPresenterIsPlayerExpanded`** — set `presenter.isPlayerExpanded = true` → the cover view appears. Set to false → it dismisses. Mutates: wiring it to a different state fails.

14. **`testNavigationHostView_epubRoute_setsIsReaderActiveTrue`** — push an `.epub(BookRoute)` route on a test coordinator; assert `presenter.isReaderActive == true` after the destination renders.

15. **`testNavigationHostView_popsEpubRoute_setsIsReaderActiveFalse`** — push then pop → presenter back to `false`. (Pairs with 14 to lock in the round-trip per CLAUDE.md state-machine wiring rules.)

### State-machine round-trip wiring

16. **`testReaderActive_drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf`** — push `.epub` (→ true), pop (→ false), push `.pdf` (→ true), pop (→ false). Body MUST do all four transitions. Per CLAUDE.md DoD #3 multi-step-test-body check; the test name embeds "acrossEpubAndPdf" so `check-test-name-vs-body.py` enforces both nouns are referenced.

## Files in scope for this implementer

Production:
- `Palace/AppInfrastructure/AudiobookMiniPlayerView.swift` (NEW)
- `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift` (NEW)
- `Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift` (NEW)
- `Palace/AppInfrastructure/AppTabHostView.swift` (MODIFY — add safeAreaInset + fullScreenCover)
- `Palace/AppInfrastructure/NavigationHostView.swift` (MODIFY — `.tracksReaderActive(...)` on reader cases; remove dead `.audio` destination body)

Tests:
- `PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift` (NEW)
- `PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift` (NEW)
- `PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift` (NEW)
- `PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift` (NEW)

## Files OFF-LIMITS to this implementer

- `Palace/Audiobooks/*` — Module C. Specifically: do NOT modify `AudiobookSessionPresenter` (consume its public API only); do NOT modify `AudiobookSessionManager`; do NOT modify `AudiobookPlayerView` (the existing full player chrome is preserved — only the gesture wrapper changes).
- `Palace/AppInfrastructure/AppContainer.swift` — Module C adds the presenter property; this module only consumes.
- `Palace/AppInfrastructure/NavigationCoordinator.swift` — do NOT remove `pushAudioRoute` / `clearAudioRoutes` / `audioModelById` (legacy compat per §6.2 point 3). After this contract, those methods are uncalled but kept; a follow-up swarm removes them.
- `Palace/CatalogUI/*`, `Palace/MyBooks/*` — Modules A / B.

## AppContainer wiring

Read-only consumer. Production `appContainer.audiobookSessionPresenter`; tests use the `AppContainer.withAudiobookSessionPresenter(_:)` modifier (if Module C added it) OR construct presenter directly and pass it down. Verify Module C's contract for the test-seam pattern before writing integration tests.

## Reduce-motion + Dynamic Type — REQUIRED

- The fullScreenCover present/dismiss animation MUST honor `UIAccessibility.isReduceMotionEnabled` — match the existing `NavigationCoordinator.push` / `pop` pattern (no `withAnimation` when reduce-motion is on).
- The mini-player chrome MUST reflow at Dynamic Type sizes AX1–AX5. Test by snapshotting at AX5 OR by asserting that the play/pause button remains hit-targetable (44pt min) when the title truncates.

## Accessibility verification (§7.1)

```bash
# Mini-player accessibility label exists:
grep -n "accessibilityLabel" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift   # >= 1

# Play/pause buttons use strings catalog (not hardcoded):
grep -n "Strings\.\|NSLocalizedString" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift   # >= 2

# Reduce-motion handled:
grep -n "isReduceMotionEnabled" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift Palace/AppInfrastructure/AudiobookMiniPlayerView.swift   # >= 1
```

## Verification criteria (grep-able)

```bash
# 1. New views exist:
grep -c "struct AudiobookMiniPlayerView" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift   # >= 1
grep -c "struct AudiobookFullPlayerCoverContainer" Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift   # >= 1
grep -c "struct IsReaderActiveTrackingModifier" Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift   # >= 1
grep -c "func tracksReaderActive" Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift   # >= 1

# 2. AppTabHostView wires safeAreaInset + fullScreenCover:
grep -n "safeAreaInset" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1 hit
grep -n "AudiobookMiniPlayerView" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1 hit
grep -n "AudiobookFullPlayerCoverContainer\|isPlayerExpanded" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1 hit
grep -n "fullScreenCover" Palace/AppInfrastructure/AppTabHostView.swift   # >= 1 hit (new presenter-driven cover)

# 3. NavigationHostView wires reader suppression:
grep -n "tracksReaderActive" Palace/AppInfrastructure/NavigationHostView.swift   # >= 3 hits (.epub, .pdf, presentedEPUBSample)

# 4. Suppression predicate exists in mini-player:
grep -n "isReaderActive" Palace/AppInfrastructure/AudiobookMiniPlayerView.swift   # >= 1 hit

# 5. SUT instantiation in tests (DoD #1):
grep -c "AudiobookMiniPlayerView(" PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift   # >= 1
grep -c "AudiobookFullPlayerCoverContainer(" PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift   # >= 1
grep -c "IsReaderActiveTrackingModifier\|tracksReaderActive" PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift   # >= 1
grep -c "AppTabHostView(" PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift   # >= 1
python3 scripts/check-test-name-vs-body.py PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift   # exit 0
python3 scripts/check-test-name-vs-body.py PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift   # exit 0

# 6. Round-trip test exists (CLAUDE.md state-machine wiring):
grep -in "drivenThroughTwoRoutePushes_andTwoPops_acrossEpubAndPdf\|acrossEpubAndPdf" PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift   # >= 1

# 7. Reader suppression test exists for both reader types:
grep -in "epubRoute_setsIsReaderActiveTrue" PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift   # >= 1

# 8. Mutation pass — REQUIRED diff-scoped ≥50% (DoD #5; AppInfrastructure touching critical-path presenter):
python3 scripts/palace_mutate.py --file Palace/AppInfrastructure/AudiobookMiniPlayerView.swift --tests AudiobookMiniPlayerViewTests --diff-only
python3 scripts/palace_mutate.py --file Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift --tests AudiobookFullPlayerCoverContainerTests --diff-only

# 9. Blast-radius (DoD #9):
python3 scripts/check-blast-radius.py --quiet   # exit 0

# 10. Build + verify-pr (DoD #6):
xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5
scripts/verify-pr.sh --quick

# 11. Settings tab still shows mini-player (§11 row 7):
# Manual smoke test (acceptable): launch app, start audiobook, switch to Settings tab → mini-player MUST remain visible. Document in PR body with a screenshot.

# 12. Mini-player suppressed on reader (§7.3 Option α):
# Manual smoke test (acceptable): start audiobook, open an EPUB or PDF → mini-player MUST disappear. Pop reader → mini-player MUST reappear.
```

## pbxproj wiring

```bash
ruby scripts/pbxproj_add_swift.rb Palace/AppInfrastructure/AudiobookMiniPlayerView.swift
ruby scripts/pbxproj_add_swift.rb Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift
ruby scripts/pbxproj_add_swift.rb Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/AppInfrastructure/AudiobookMiniPlayerViewTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/AppInfrastructure/AudiobookFullPlayerCoverContainerTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/AppInfrastructure/IsReaderActiveTrackingModifierTests.swift
ruby scripts/pbxproj_add_swift.rb PalaceTests/AppInfrastructure/AppTabHostMiniPlayerIntegrationTests.swift
```

## Scope-deferral protocol

If ViewInspector / SwiftUI testing infrastructure is missing for any of tests 10–16 (the on-appear/disappear/gesture/integration tests), STOP and propose:
- (a) ship behavior-only tests that invoke the modifier closure directly (less coverage, but mechanically valid);
- (b) extend scope to add a thin SwiftUI test harness;
- (c) substitute a UIKit-host-based test that adds the view to a UIWindow and reads back the published value.

Do NOT silently ship "tests" that don't actually exercise the SwiftUI lifecycle.

## Risk classification

**Critical_path.** Touches root presentation. The §7.3 reader-suppression is the load-bearing failure mode — if the predicate misses a route case, the mini-player flashes over Reader2 / Reader3, breaking the §11 row 7 user-visible contract. Mutation pass is MANDATORY (≥50% diff-scoped). The integration tests 12–16 are the verification gate; if they cannot be written mechanically, propose the deferral above before declaring READY.

This contract preserves three load-bearing invariants:
1. **§7.3 reader suppression** — mini-player hidden on `.epub` / `.pdf` / `presentedEPUBSample`. Tested via tests 14–16.
2. **§11 row 7 Settings visibility** — mini-player visible on Settings tab. Tested via the manual smoke test (Settings is a non-reader route; the predicate `!isReaderActive` keeps it visible).
3. **F-011 first-open expand** — root `fullScreenCover` opens because `presenter.isPlayerExpanded == true` after Module C's `presentOnFirstOpen()`. This contract's job is to bind the cover to the published value; Module C's `presentOnFirstOpen()` test plus this contract's test 13 jointly cover the path.
