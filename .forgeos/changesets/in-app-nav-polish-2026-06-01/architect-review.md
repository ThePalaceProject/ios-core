# Architect post-review — polish fix-contract

**Verdict:** BLOCKED
**Reviewer:** architect-reviewer (Phase 1a / /rigorous-fix)
**Date:** 2026-06-01

## Summary

The fix-contract picks the right scope (3 user-verified bugs + originally-deferred P5 polish, single critical-path /rigorous-fix bundle) and correctly identifies the architectural pattern (route skip controls through `AudiobookSessionManaging` because `AudiobookPlaybackModel.audiobookManager` is internal-default and unreachable from Palace). However, two of the contract's load-bearing factual claims are **wrong**, and one structural side-effect of the protocol change is **not enumerated** anywhere in scope, off-limits, or risk callouts. Both block.

## Findings

### Critical (block)

**C1. Fix-contract cites `AudiobookSessionManager.swift:486` as `manager?.audiobook.player.skipPlayhead(±30)` — this call does not exist.**

Verification: `grep -n "skipPlayhead\|skipBack\|skipForward" Palace/Audiobooks/AudiobookSessionManager.swift` returns 0 matches. Line 486 is `guard let manager = manager else {` inside `play()`. The full file has zero references to `skipPlayhead`.

This matters because the contract's resolution narrative ("`AudiobookSessionManager` implements them by chaining through its own `manager` reference (already at AudiobookSessionManager.swift:486 — `manager?.audiobook.player.skipPlayhead(±30)`)") implies the chaining target already exists and the implementer is just exposing it. It does NOT exist. The implementer must ADD `skipBack()` / `skipForward()` methods to `AudiobookSessionManager` that call `manager?.audiobook.player.skipPlayhead(...)` with the toolkit's `async` signature (`func skipPlayhead(_ timeInterval: TimeInterval) async -> TrackPosition?` at `Player.swift:108`). That's a real Task { @MainActor in ... } sync-to-async boundary — same pattern as the existing `skipToChapter` at AudiobookSessionManager.swift:526-528 — not a one-line forward.

Recommendation: rewrite the "Skip-control plumbing — RESOLVED" paragraph in fix-contract Bug 3 to (a) acknowledge the toolkit `skipPlayhead` is `async`, (b) cite the correct pattern reference (skipToChapter at lines 524-528 is the precedent for sync→async boundary inside the session manager), (c) drop the false ":486" citation.

**C2. Adding `skipBack()` / `skipForward()` to `AudiobookSessionManaging` protocol cascades to 4 test-target conformers not enumerated in scope.**

Verification: `grep -rn "AudiobookSessionManaging" Palace PalaceTests | grep -E ":[A-Za-z]+: AudiobookSessionManaging"` finds the following conformers:

- `Palace/Audiobooks/AudiobookSessionManager.swift` (production — in scope)
- `PalaceTests/Mocks/SpyAudiobookSessionPresenter.swift:140` (`SpyShimSession`)
- `PalaceTests/ViewModels/ActiveSessionsViewModelTests.swift:386` (`FakeAudiobookSessionManager`)
- `PalaceTests/CatalogUI/CatalogViewContinueRowsIntegrationTests.swift:299` (`FakeIntegrationAudiobookSession`)
- `PalaceTests/CatalogUI/ContinueRowSectionTests.swift:353` (per grep — yet another fake)

The contract's "Scope (out)" section names nothing in `PalaceTests/`. The "Risk callouts" section mentions only the `AudiobookMiniPlayerView.init` API change, not the protocol change. Adding methods to `AudiobookSessionManaging` is a **protocol-conformance compilation break** on all five sites — Palace will not build until every fake / spy is updated. The implementer needs explicit license to touch those test-only conformers, and the contract needs to either name them in scope OR enumerate them in risk callouts so the integrator knows what to expect.

Recommendation: add a "Scope (in) — protocol-conformance fan-out" sub-section listing the 5 conformers and stating that each must add no-op (or assertion-recording) `skipBack()` / `skipForward()` implementations. OR pick an alternative architecture that does not extend the protocol — e.g., expose `skipBack` / `skipForward` only on the concrete `AudiobookSessionManager` and have the mini-player resolve through `appContainer.audiobookSession as? AudiobookSessionManager` (rejected by symmetry — but worth naming so the choice is conscious).

**C3. Bug 2 contract subscribes to `playbackModel.$currentLocation` but does not specify re-subscribe semantics on `adoptPlaybackModel(_:)`.**

`AudiobookSessionPresenter.adoptPlaybackModel(_:)` (line 164) replaces the stored `playbackModel`. If the presenter subscribes to `playbackModel.$currentLocation` once at init time (when `playbackModel == nil`), no subscription exists. If it subscribes inside `adoptPlaybackModel`, every adoption leaks the prior subscription unless the presenter cancels it first.

The contract's Bug 2 wording ("Subscribe via Combine to: ... `playbackModel.$currentLocation`") is silent on this. The "round-trip wiring tests required for state machines" pin from CLAUDE.md applies here: switching audiobooks (PP-3783 contract) MUST re-subscribe cleanly, or the second audiobook's positions never propagate.

Recommendation: add to Bug 2 contract: "On every `adoptPlaybackModel(_:)` call, cancel any prior `currentLocation` subscription and re-subscribe to the new model's `$currentLocation`. Add `testPresenter_currentLocationMirrorsAfterPlaybackModelReplacement` — adopt model A, drive A's currentLocation, adopt model B, drive B's currentLocation, assert presenter mirrors B only." The existing `testPresenter_currentLocationMirrorsPlaybackModel` is necessary but not sufficient (it covers the single-model case, not the replacement contract that PP-3783 exercises).

### Significant (block)

**S1. Contract claims toolkit `Player.skipPlayhead` is "public" — accurate but for the wrong reason; also misstates AudiobookPlaybackModel.audiobookManager access.**

Contract Bug 3 "Scope (out)" says "The `Player.skipPlayhead(_:)` API is already public (line 108 of `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Player.swift`); use it directly." Verification: `Player.swift:84` declares `public protocol Player: NSObject`, so the requirement `func skipPlayhead(...)` IS accessible at the protocol's `public` access level — the method itself has no explicit modifier, but as a requirement of a public protocol it is reachable externally. Correct outcome, slightly misleading reason. Not a blocker on its own.

Bigger issue: contract Bug 3 elsewhere asserts "`AudiobookPlaybackModel.audiobookManager` is internal-access in the toolkit, so the mini-player CANNOT reach it directly." Verification: `AudiobookPlaybackModel.swift:25` declares `private(set) var audiobookManager: AudiobookManager` — no `public`, so the **getter** is internal-default. External Palace code reading `playbackModel.audiobookManager` is blocked at compile time. Contract is correct — but the second "Risk callouts" paragraph contradicts this by suggesting "`AudiobookMiniPlayerView` calls `playbackModel.audiobookManager.audiobook.player.skipPlayhead(_:)` directly" as a plan. The plan is dead-on-arrival; the resolved-in-scope text (Bug 3) is correct. Risk-callout paragraph should be deleted (it's superseded) so the implementer doesn't waste a cycle trying the dead path.

Recommendation: delete the "Toolkit reachability for skip controls" paragraph from "Risk callouts" since the in-scope text already settled this. Replace with a single line: "Skip controls route through `AudiobookSessionManaging.skipBack()` / `skipForward()` (added by this contract). Toolkit untouched."

### Advisory

**A1. CarPlay test class enumeration is missing one class.**

Contract enumerates 7 CarPlay regression classes: `CarPlayTests`, `CarPlayIntegrationTests`, `CarPlayOpenAppAlertTests`, `CarPlayLibraryRefreshTests`, `CarPlayNowPlayingTemplateTests`, `CarPlayChapterListTests`, `CarPlayPlaybackErrorTests`. Verification (`grep -n "^class\|^final class" PalaceTests/CarPlay/CarPlayTests.swift`) confirms all 7 exist plus an 8th: `CarPlayAudiobookBridgePresenterMigrationTests` at line 634. There is also `PalaceTests/CarPlay/CarPlayAuthHelperReadinessTests.swift`.

The Bug 2 presenter-reactivity changes ARE invisible to CarPlay's direct `playbackStatePublisher` subscription (contract is right), but `CarPlayAudiobookBridgePresenterMigrationTests` exercises the presenter-migration plumbing CarPlay uses — that test class IS at risk if Bug 2 reorders publisher emissions. Add to the regression gate.

The test counts cited ("36/36 pass", "21/21 pass") are off — actual counts are ~41 CarPlay + 32 LCP. Not load-bearing; just imprecise.

Recommendation: add `CarPlayAudiobookBridgePresenterMigrationTests` + `CarPlayAuthHelperReadinessTests` to the regression-gate list. Update counts or drop the totals (the class enumeration is the load-bearing part).

**A2. Verification grep `grep -c "isPlayingProvider:\|coverImageProvider:" Palace/` is missing `-r`.**

On macOS `grep -c "..." Palace/` treats `Palace/` as a single argument; it does not recurse. Without `-r` the grep emits per-file counts only for files (returning 0 across config files) and misses the actual Swift sources. The contract intent is "no Palace source under `Palace/` references those closures" — needs `grep -rc ... Palace/Audiobooks/ Palace/AppInfrastructure/` or `grep -rc ... Palace/` to recurse.

Recommendation: change to `grep -rc "isPlayingProvider:\|coverImageProvider:" Palace/Audiobooks/ Palace/AppInfrastructure/ | grep -v ":0$"` — empty output = pass.

**A3. The "fall back to subscribing to `sessionManager.coverImage` via timer/state-publisher fan-out" plan in Bug 2 is vague.**

Contract Bug 2 says of `coverImage`: "subscribe to `playbackStatePublisher` (fires on bind), snapshot `sessionManager.coverImage` into `presenter.coverImage` from the sink. Update with `coverImage` setter in `adoptPlaybackModel` for the initial snapshot." This is a polling-via-publisher-event strategy — it'll work for "cover changed on bind" but will miss updates between binds (e.g., `loadCoverArt(for:into:)` at AudiobookSessionManager.swift:721+ updates the cover asynchronously after bind: lo-res sync, hi-res via Task). The async hi-res replacement will not fire `playbackStatePublisher`, so the presenter's cover will stay at lo-res indefinitely after first bind.

Recommendation: either (a) add a `coverImagePublisher: CurrentValueSubject<UIImage?, Never>` to `AudiobookSessionManaging` (cleanest; one more protocol fan-out site — see C2) and subscribe directly; or (b) have `AudiobookSessionManager.updateCoverImage(_:)` (line 87 of `AudiobookSessionManaging.swift`) also flip a state-publisher event that the presenter listens for. Document the chosen path.

**A4. Rigor-bar judgment: keep /rigorous-fix.**

CLAUDE.md "Multi-module orchestration — /swarm" rule says ≥2 modules → /swarm. This change touches `Palace/Audiobooks/` (3 files: presenter, manager, protocol) AND `Palace/AppInfrastructure/` (3 files: mini-player, full-player container, tab host). Count-wise that's two modules. However, the architectural dependency is one-way (presenter publishes → views consume; protocol expanded → session manager + views update in lockstep) — the work cannot be sensibly parallelized because Bug 3 mini-player code depends on Bug 2 presenter @Published surface AND the protocol additions. /swarm's parallel-implementer dispatch would force false splits and integration churn.

CLAUDE.md "Risk-driven rigor bar" explicitly carves out: "For single-module work in a critical path, use the `/rigorous-fix` skill (or `/swarm --solo`) — runs architect + SoD review without parallel implementers." Critical-path coverage applies here (Palace/Audiobooks/ is explicitly listed). The bundled scope (Bug 1 + Bug 2 + Bug 3 + P5) is one logical change with one rollback unit. Keep /rigorous-fix.

Recommendation: no change. /rigorous-fix is the right bar. If the implementer hits the protocol-cascade in C2 and finds it ballooning beyond budget, escalate to /swarm only for the test-conformer updates (which are mechanical), not for the production code.

## Verification work performed

1. Read `.forgeos/changesets/in-app-nav-polish-2026-06-01/fix-contract.md` (156 lines), `docs/architecture/areas/audiobook/verification-checklist.md` (173 lines), `docs/architecture/in-app-navigation-during-playback.md` (296 lines).
2. Read every cited Palace file: `AudiobookSessionPresenter.swift`, `AudiobookSessionManaging.swift`, `AudiobookMiniPlayerView.swift`, `AudiobookFullPlayerCoverContainer.swift`, `AppTabHostView.swift`.
3. Searched `AudiobookSessionManager.swift` for `skipPlayhead|skipBack|skipForward` — 0 matches in production code (C1 finding).
4. Read `ios-audiobooktoolkit/PalaceAudiobookToolkit/UI/AudiobookPlaybackModel.swift` lines 13-30, 405-450 + grepped access modifiers — confirmed `audiobookManager` is `private(set) var` (internal-getter), `skipBack`/`skipForward` are internal-default, `coverImage` and `playbackProgress` are internal-default `@Published`, `currentLocation` IS `@Published public`.
5. Read `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/Player.swift:84-120` — confirmed `Player` is `public protocol`, `skipPlayhead` is `async`, `play(at:)` is `async throws`.
6. Grepped all `AudiobookSessionManaging` conformers across `Palace` + `PalaceTests` — found 5 conformer sites (C2 finding).
7. Ran each verification-criteria grep against the current pre-fix codebase — confirmed they parse and return 0 hits (expected pre-fix); flagged the `Palace/` no-recurse grep (A2 finding).
8. Counted CarPlay test classes — confirmed all 7 named exist, found 1 extra (`CarPlayAudiobookBridgePresenterMigrationTests`) missing from the regression-gate list (A1 finding).
9. Confirmed F-011 test name (`testOpenAudiobook_firstOpen_setsPresenterIsPlayerExpandedTrue_beforeReadinessGateCompletes`) exists at AudiobookSessionManagerPresenterMigrationTests.swift:204; PP-3783 test (`testOpenAudiobook_switchingAudiobooks_clearsPreviousPlaybackModel`) exists at line 160. Both regression gates point at real tests.
10. Confirmed `loadCoverArt(for:into:)` at AudiobookSessionManager.swift:721+ updates cover asynchronously via two paths (lo-res sync, hi-res async Task), which informs A3.

## Recommendation

**BLOCKED — three contract amendments required before Phase 2 implementation:**

1. Fix C1: rewrite the "Skip-control plumbing — RESOLVED" paragraph. Drop the false `:486` citation. Cite `skipToChapter` at AudiobookSessionManager.swift:524-528 as the sync→async chaining precedent. Note `skipPlayhead` is `async -> TrackPosition?` so the new methods on the manager must wrap in `Task { @MainActor in ... }`.

2. Fix C2: add a "Scope (in) — protocol-conformance fan-out" sub-section enumerating the 5 `AudiobookSessionManaging` conformer sites. Either license the implementer to add no-op `skipBack/skipForward` to each test mock, or change the architecture (concrete-only method, mini-player resolves via cast — and accept the rejected-alternative cost).

3. Fix C3: add re-subscribe semantics to Bug 2's `playbackModel.$currentLocation` subscription. Add test `testPresenter_currentLocationMirrorsAfterPlaybackModelReplacement` covering the PP-3783 audiobook-switch case.

4. Suggested non-blocking polish (S1, A1-A3): delete superseded Risk-callouts paragraph; add `CarPlayAudiobookBridgePresenterMigrationTests` to regression gate; fix `Palace/` grep recursion; choose `coverImage` propagation strategy explicitly.

Once amended, Phase 2 (ForgeOS changeset propose + TDD implementation) can proceed. The selected architectural pattern (route skip via protocol extension; presenter mirrors via Combine subscriptions) is sound; the contract just needs to be honest about what's there and what isn't, and to enumerate the protocol-cascade so the implementer doesn't get blindsided at first `xcodebuild build`.

---

## Contract amendments applied (2026-06-01 orchestrator pass)

All 3 critical findings addressed in the fix-contract:

- **C1 fix:** "Skip-control plumbing" section rewritten to: "AudiobookSessionManager adds `skipBack()`/`skipForward()` that wrap toolkit's async `Player.skipPlayhead` via `Task { await player.skipPlayhead(±30) }` — same pattern as `skipToChapter(at:)` at AudiobookSessionManager.swift lines 524-528." The fabricated "line 486" claim removed.
- **C2 fix:** Protocol-cascade enumeration added — 4 conformers named (SpyShimSession, FakeAudiobookSessionManager, FakeIntegrationAudiobookSession, fake in ContinueRowSectionTests). Each gets a no-op or call-counter implementation.
- **C3 fix:** Re-subscribe semantics added to `adoptPlaybackModel(_:)`. Separate `playbackModelCancellables` set; `.removeAll()` before re-subscribing. New test `testPresenter_adoptsNewPlaybackModel_clearsPriorCurrentLocationSubscription` required.

Advisory cleanups also applied:
- Self-contradicting toolkit-reachability paragraph in "Risk callouts" rewritten to reference scope item 3's resolution.
- `CarPlayAudiobookBridgePresenterMigrationTests` added to the CarPlay regression-test list.
- coverImage strategy: snapshot at `adoptPlaybackModel` + `AudiobookSessionManager.updateCoverImage(_:)` forwards to `presenter.adoptCoverImage(_:)` for async hi-res arrivals.

Orchestrator decision: proceeding to Phase 2 WITHOUT re-spawning a second architect-reviewer pass. The architectural pattern was APPROVED-in-principle; the 3 critical findings were contract-completeness issues, not design issues. The amendments are mechanically verifiable; if any prove wrong during implementation, the Phase 4 /forge-review will catch them.
