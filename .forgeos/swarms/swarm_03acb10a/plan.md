# Swarm 3 — Singleton Elimination + Async Sweep

**Phase 3 of [audiobook-systemic-overhaul](../../../docs/architecture/audiobook-systemic-overhaul.md).**

Stacks on top of Swarm 2 (`swarm_f4fbef9c-scaffold`, PR #980 open). That branch contains Swarm 1's vendor adapter extraction (PR #979) too. When #979 and #980 merge, this swarm rebases to develop.

## Pre-triage reconnaissance against current code

| Concern | ADR plan | Actual state |
|---|---|---|
| `AudiobookSessionManager.shared` | remove `static let shared` | exists at `AudiobookSessionManager.swift:87`; file is 1073 LOC |
| `PlaybackBootstrapper.shared` | remove `static let shared` | exists at `PlaybackBootstrapper.swift:56`; file is 458 LOC |
| `.shared` production callers | "audit all sites" | **3 production sites**: `CarPlaySceneDelegate.swift:43`, `TPPAppDelegate.swift:55`, `BookService.swift:75` |
| `AudiobookLoader.swift` callback pyramid | "rewrite to async pipeline" | Swarm 1 already restructured to adapter dispatch; 418 LOC; minimal pyramid remains |
| `DispatchQueue.main.asyncAfter` in `Palace/Audiobooks/` | "structured concurrency sweep" | **1 actual call** (`NowPlayingCoordinator.swift:280`); the AudiobookDataManager occurrence is a comment about *historical* asyncAfter |
| `AudiobookDataManager` background tasks | `Task.detached + @MainActor` | UIApplication.beginBackgroundTask + syncQueue patterns at lines 149-160 |
| AppContainer audiobook surface | per-account factory | **does not exist yet** — Module A creates it |
| Test workarounds (`setUp resets shared mock`) | "delete all instances" | architect will inventory |

**Net: Swarm 3 is significantly smaller than the ADR predicted.** Swarm 1 already absorbed most of the callback-pyramid rewrite. Only the singleton elimination + 1 explicit asyncAfter + AudiobookDataManager structured-concurrency migration remain.

## Module partition (must be disjoint — verified by architect triage)

| Module | Owner files (exclusive write) | Depends on |
|---|---|---|
| **A** — AppContainer wiring | MOD `Palace/AppInfrastructure/AppContainer.swift` (add `audiobookSession` per-account factory + `playbackBootstrapper`); NEW `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift` | — |
| **B** — Singleton elimination | MOD `Palace/Audiobooks/AudiobookSessionManager.swift` (remove `static let shared`; constructor signature accepts dependencies); MOD `Palace/Audiobooks/PlaybackBootstrapper.swift` (remove `static let shared`); MOD `Palace/AppInfrastructure/TPPAppDelegate.swift:55`; MOD `Palace/CarPlay/CarPlaySceneDelegate.swift:43`; MOD `Palace/Book/UI/BookDetail/BookService.swift:75` (3 call-site edits to use `AppContainer.production().audiobookSession`); MOD `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` + sibling test files (replace shared-state setUp with injection) | A |
| **C** — AsyncAfter sweep + structured concurrency | MOD `Palace/Audiobooks/NowPlayingCoordinator.swift:280` (`DispatchQueue.main.asyncAfter` → `Task.sleep`); MOD `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (background tasks → `Task.detached(priority:)` + `@MainActor`); MOD `Palace/Audiobooks/AudiobookLoader.swift` ONLY if residual non-adapter callback pyramid surface remains (architect verifies — likely no edits) | — (independent of A and B) |
| **D** — Test cleanup | DELETE `setUp resets shared mock` workaround patterns from Audiobook + SAML tests (architect to inventory); MOD flake-timeout bumps that traced to shared-state contention; net-negative LOC | A, B, C |

## Don't-touch (cross-swarm hygiene)

- `Palace/Audiobooks/Vendors/` (Swarm 1 PR #979 territory)
- `Palace/Audiobooks/AudiobookLoader.swift` UNLESS architect identifies residual pyramid surface and explicitly authorizes Module C
- `Palace/Audiobooks/LCP/LCPAudiobooks.swift` (Swarm 1 — `hasLCPAcquisition` predicate)
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (Swarm 2 PR #980)
- `Palace/Reader2/BusinessLogic/TPPLastReadPosition*.swift` (Swarm 2)
- `Palace/Reader2/Bookmarks/AudiobookPositionAdapter.swift` (Swarm 2)
- `Palace/Reader2/BusinessLogic/EPUBPositionAdapter.swift` (Swarm 2)
- `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` (Swarm 2)
- `Palace/Packages/PalaceReadingPosition/` (Swarm 2 SPM)
- `Palace/Audiobooks/AudiobookPositionPolicy.swift` (P0 swarm_f3b9b087 read-side restoration — not in any active swarm but architecturally adjacent)
- `Palace/CarPlay/` files OTHER than `CarPlaySceneDelegate.swift:43` (PR #968 settled)
- `ios-audiobooktoolkit/` (toolkit submodule — parallel T1+T2 workstream)
- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` (read-side restoration regression gate)

## Acceptance gates

1. **`grep "static let shared" Palace/Audiobooks/`** returns 0
2. **`grep "AudiobookSessionManager.shared\|PlaybackBootstrapper.shared" Palace --include="*.swift"`** returns 0 outside `Palace/AppInfrastructure/AppContainer.swift` itself
3. **`grep "DispatchQueue.main.asyncAfter" Palace/Audiobooks/`** returns 0 (excluding comments)
4. **No callback pyramid ≥3 deep in `Palace/Audiobooks/`** — architect verifies
5. **100% mutation kill rate** on `AudiobookSessionManager` lifecycle methods (via `palace_mutate.py --diff-only`)
6. **All existing audiobook tests continue to pass** — `AudiobookSessionManagerTests`, `PlaybackBootstrapperTests`, `AudiobookPositionPolicyTests`, `AudiobookLoaderPredicateTests`, etc.
7. **`AudiobookLoader.swift` LOC unchanged or smaller** vs Swarm 1's 418-LOC tip
8. **AppContainer audiobookSession factory ≤80 LOC** added to AppContainer
9. **`scripts/verify-pr.sh --quick`** passes
10. **`mcp__forgeos__forge_check_gates`**: architect + qa_test gates satisfied
11. **Net negative LOC on test cleanup (Module D)** — workarounds removed > new shims added
12. **No edits in don't-touch list**

## Architect triage requirement (per Swarm 1 + 2 lesson)

Before dispatch, an architect agent reads:
- This plan + the ADR section "Phase 3 — Swarm 3"
- AudiobookSessionManager.swift (full file, 1073 LOC) — what does the singleton actually own? account-coupled? lifecycle-coupled?
- PlaybackBootstrapper.swift (458 LOC) — what's the CarPlay startup invariant it protects?
- AppContainer.swift current shape — what's the per-account injection pattern landed by #967?
- All 3 `.shared` call sites — what state do they expect?
- NowPlayingCoordinator.swift:280 — what's the asyncAfter sequencing?
- AudiobookDataManager.swift:149-160 — UIApplication.beginBackgroundTask migration scope
- `setUp resets shared mock` test pattern — `grep -rn "TPPBookRegistryMock.*shared\|reset.*shared\|setUp.*shared" PalaceTests --include="*.swift"` — locate all instances + decide which are addressable here vs left as follow-ups
- AudiobookLoader.swift (418 LOC) — verify minimal-to-zero residual pyramid surface

**Deliverable:** refined `contracts/{A,B,C,D}.md` + `transcripts/triage.md` with deviation list + dispatch verdict.

## Predicted timeline (post-recon)

Architect triage: 30-45 min wallclock
Module A: 30-45 min (smaller than Swarm 2's A — no SPM extraction)
Module B: 60-90 min (3 call-site migrations + test file edits; the test edits are the bulk)
Module C: 45-60 min (only 1 explicit asyncAfter + AudiobookDataManager structured-concurrency)
Module D: 30-45 min (test cleanup)
Integrator: 30-45 min

Total: ~3-4 hours orchestrator wallclock. Matches Swarm 2's actual.

## Swarm methodology lessons applied

1. **Architect triage is high-leverage** — Swarm 2 architect caught 7 deviations; Swarm 1 caught 5. This swarm's recon already surfaced the smaller scope; architect validates against current code.
2. **Implementer transcripts written FIRST** — Swarm 1 had 2 stream timeouts at transcript step; Swarm 2 had zero after applying this pattern. Keep it.
3. **Worktree submodule setup** — `ios-audiobooktoolkit` MUST be a real clone (not symlink) per memory `feedback_worktree_palace_setup.md`. Already done preemptively.
4. **Defaulted parameter pattern** — avoids editing files in other swarms' don't-touch lists. Worked twice in Swarm 2. Use again for AudiobookSessionManager init.
5. **PR vocabulary clean** — no swarm IDs / Module A-D labels in the eventual PR body (per memory `feedback_no_swarm_refs_in_pr.md` added 2026-05-21).
