# Swarm plan — swarm_0b7616e7

## Goal

Implement P1+P2+P3+P4 of `docs/architecture/in-app-navigation-during-playback.md` — Audible-style persistent audiobook mini-player + "Continue Reading" / "Continue Listening" Catalog rows. Target release 3.3.0. Production quality from the start ("prototype that converts").

P0 (the design doc) is already merged on this scaffold branch. P5 (polish) and P6 (delete legacy `AppRoute.audio` + NavigationCoordinator audio-route methods) are deferred per user's explicit scope.

## Module split (4 implementers)

| Module | Owner area | Risk | Phases | Parallel-with |
|---|---|---|---|---|
| **A** — `RecentlyReadingService` + `ActiveSessionsViewModel` | MyBooks / CatalogUI (ViewModel) | standard | P1 + P2 data layer | C |
| **B** — Catalog Continue rows UI | CatalogUI + AppTabHostView wiring | standard | P1 + P2 UI | (depends on A) |
| **C** — `AudiobookSessionPresenter` + `pushAudioRoute` migration | Audiobooks + CarPlay + AppContainer | critical_path | P3 + P4 (Audiobooks side) | A |
| **D** — AppTabHostView mini-player + root `fullScreenCover` + reader suppression | AppInfrastructure (root presentation) | critical_path | P3 + P4 (AppInfrastructure side) | (depends on C) |

### Why 4 and not 2 or 6

- **A and C are pure-additive and touch disjoint files** — they can ship in parallel and meet at integration. Splitting them is the only way to keep the implementer prompts focused on a single concern.
- **B depends on A** (consumes `ActiveSessionsViewModel`); **D depends on C** (consumes `AudiobookSessionPresenter`). Each consumer is a different module, so the dependency lines are clean.
- Folding B into A would expand A's scope from "data layer" to "UI integration" — different review domains (Catalog view design vs registry query semantics). Folding D into C would put `AppTabHostView` edits in the same diff as `AudiobookSessionManager` migration — the reviewer-blocked wall-failure pattern (PR #1018 Module C) lives in exactly that shape.

## Parallelism plan

```
Phase 1 (parallel):
    A — RecentlyReadingService + ActiveSessionsViewModel
    C — AudiobookSessionPresenter + AudiobookSessionManager migration + CarPlay bridge update

Phase 2 (parallel — after A and C READY):
    B — Catalog Continue rows UI integration
    D — AppTabHostView mini-player + root fullScreenCover + reader suppression
```

Sequential reviewers for the critical-path modules (C, D) — both get architect + qa_test + clean_code + blast_radius. The standard modules (A, B) get architect + qa_test + clean_code.

## Risks

1. **Audiobook hoist regression** (CarPlay / F-011 / PP-3783) — Module C's risk. Mitigated by mandatory mutation pass (≥50% diff-scoped), CarPlay smoke regression in the contract, F-011 first-open expand test, and PP-3783 switching-books test.

2. **Mini-player flashes over reader** (§7.3 Option α failure mode) — Module D's risk. Mitigated by tests 14–16 in Module D, the `IsReaderActiveTrackingModifier` single-place-to-maintain pattern, and manual smoke test in PR body.

3. **Continue Reading semantics drift across renderers** (TPPBookLocation.locationString JSON shape varies) — Module A's risk. Mitigated by the scope-deferral protocol in A: if parsing entangles, ship with `progressFraction: nil` for unknown renderers and document the gap, rather than parsing wrong.

4. **AppTabHostView view-hierarchy collision** — adding `safeAreaInset` could interact with existing tabBar layout or the holds badge. Mitigated by Module D test 12 (`safeAreaInset` contains mini-player) and the existing `holdsBadgeCount` flow being untouched.

5. **AppContainer test-seam pattern** — Module C adds `audiobookSessionPresenter` as a computed-property + cached static, following the `audiobookSession` precedent. Module D consumes it. If Module D's integration tests need a spy presenter and the test seam isn't ready, the deferral protocol kicks in (Module D's contract).

6. **NavigationCoordinator legacy compat** — pushAudioRoute and audioModelById stay alive but unused per §6.2 point 3. A follow-up swarm removes them after this swarm is verified in 3.3.0. The contracts explicitly forbid touching NavigationCoordinator in this swarm to keep the blast radius bounded.

## Acceptance criteria

Each module reports READY only with all 10 DoD checks evidenced (per CLAUDE.md Definition of Done). Specifically, all four modules MUST paste:

1. SUT instantiation check pass (grep + `check-test-name-vs-body.py` exit 0).
2. Function-result usage check pass.
3. Multi-step test body check pass (named tests must do what they claim).
4. Scope coverage audit pass (every contract item is in the diff OR scope-deferred explicitly).
5. **Mutation pass** — for C and D (critical_path): MUST be ≥50% diff-scoped, ideally 100% on touched lines. For A and B (standard): MUST be ≥50% diff-scoped per `verify-pr.sh --quick` default mode.
6. Build + verify-pr pass.
7. Multi-step / wiring claim coverage (line coverage on cited lines).
8. Contract reconciliation pass (`check-contract-reconciliation.py` exit 0).
9. Blast-radius check pass (`check-blast-radius.py` exit 0).
10. Adjacency staleness check (warn-only; paste output).

Module C additionally pastes:
- CarPlay smoke regression test result.
- LCP streaming smoke test result (if class exists).

Module D additionally pastes:
- Manual smoke evidence: Settings tab mini-player visibility screenshot + reader-route mini-player suppression screenshot.

## Sequencing

Phase 1 dispatch: A and C in parallel.

Phase 2 dispatch (after both A and C are READY and integrated): B and D in parallel.

Integration step between Phase 1 and Phase 2: orchestrator merges A and C onto the swarm scaffold branch, runs `verify-pr.sh --quick`, then dispatches B and D off the merged state.

Final integration: B and D merged, full `verify-pr.sh --quick --enforce-mutations` run, forge-review with the four required reviewer roles, PR opened to `develop`.

## Anti-scope (do NOT touch in this swarm)

- `Palace/Audiobooks/NowPlayingCoordinator.swift` (§7.2 — must not change CarPlay publisher contract).
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (warm-start invariant).
- `Palace/AppInfrastructure/NavigationCoordinator.swift` — `pushAudioRoute`, `clearAudioRoutes`, `isTopRouteAudio`, `audioModelById` stay (legacy compat per §6.2 point 3 — removal is a follow-up).
- `Palace/AppRoute.audio` enum case — kept; only the dead destination renderer in `NavigationHostView` is removed.
- `Palace/Reader2/`, `Palace/Reader3/`, `Palace/PDF/` — reader internals unchanged.
- iPad split-view (§10 out of scope).
- PiP / mini-reader for ebooks (§10 out of scope).
- Listen-along sync mode (§10 out of scope).
- New persisted state schema (§10 out of scope — reuse TPPBookLocation + AudiobookSessionManager state).
- Adobe RMSDK / LCP DRM code paths.
- ios-audiobooktoolkit submodule.
- `release/3.2.0`, `develop`, `main` directly — work happens on `swarm/swarm_0b7616e7-scaffold`.

## Overlap audit

```
Module A files:
  Palace/MyBooks/RecentlyReadingService.swift                    [NEW]
  Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift      [NEW]

Module B files:
  Palace/CatalogUI/Views/ContinueRowSection.swift                [NEW]
  Palace/CatalogUI/Views/CatalogContentView.swift                [MODIFY]
  Palace/CatalogUI/Views/CatalogView.swift                       [MODIFY]
  Palace/AppInfrastructure/AppTabHostView.swift                  [MODIFY — adds ActiveSessionsViewModel construction]

Module C files:
  Palace/Audiobooks/AudiobookSessionPresenter.swift              [NEW]
  Palace/Audiobooks/AudiobookSessionManager.swift                [MODIFY]
  Palace/CarPlay/CarPlayAudiobookBridge.swift                    [MODIFY]
  Palace/AppInfrastructure/AppContainer.swift                    [MODIFY — adds audiobookSessionPresenter property]

Module D files:
  Palace/AppInfrastructure/AudiobookMiniPlayerView.swift         [NEW]
  Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift [NEW]
  Palace/AppInfrastructure/IsReaderActiveTrackingModifier.swift  [NEW]
  Palace/AppInfrastructure/AppTabHostView.swift                  [MODIFY — adds safeAreaInset + fullScreenCover]
  Palace/AppInfrastructure/NavigationHostView.swift              [MODIFY — adds tracksReaderActive; removes dead .audio destination body]
```

**Conflicts:**
- `Palace/AppInfrastructure/AppTabHostView.swift` is modified by both **B** (adds `ActiveSessionsViewModel` construction in `init`) and **D** (adds `safeAreaInset` + `fullScreenCover` in `body`). These touch DIFFERENT sections of the file — B inside `init`, D inside `body`. **Sequencing mitigation:** B runs first in Phase 2, D rebases on B's merged state. The integration step before Phase 2 merges B's AppTabHostView changes; D works against that merged state.

**Resolution if the conflict appears anyway:** the orchestrator's Phase 2 integration step rebases D on B's merge commit, hand-resolving any `AppTabHostView.swift` overlap. Both edits are in distinct named blocks (B's StateObject construction in `init`; D's modifier chain in `body`) so the resolution is mechanical.

## Reviewer plan (Phase 5 forge-review)

| Module | Reviewers |
|---|---|
| A | architect, qa_test, clean_code |
| B | architect, qa_test, clean_code |
| C | architect, qa_test, clean_code, blast_radius |
| D | architect, qa_test, clean_code, blast_radius |

Architect reviewer for A/B verifies the additive surface doesn't introduce new singletons or violate the AppContainer wiring pattern. Architect for C/D verifies the presenter contract matches §6.2 + §6.4, the CarPlay publisher contract is unchanged (§7.2), and F-011 first-open behavior (§7.4) is preserved.

QA test reviewer verifies behavior tests are real (not fluff per CLAUDE.md), every named multi-step test does what it claims, and mutation pass results are pasted in evidence.

Clean code reviewer runs the standard skeptic pass — DRY, dead code, force unwraps, GCD-where-async-exists, copy-paste drift.

Blast radius reviewer (C/D only) verifies no new public API leaks, no `#if DEBUG` on production paths, no test-only AppContainer init params, no discarded function results without TODO comments, and the AppContainer modification follows the existing `audiobookSession` / `signInModalSheetPresenter` precedent.

## Estimated total LOC

- Production: ~850–1450 LOC across 4 modules (~210–360 LOC per module average).
- Tests: ~1050–1650 LOC.
- Each module independently below 600 LOC prod — within the rigor-bar's pragmatic upper limit for a single implementer pass.
