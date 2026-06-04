---
name: swarm_0b7616e7-outcome
type: incident
status: complete
created: 2026-06-01
last_refresh: 2026-06-01
freshness_window: 365d
owners: [general]
description: Final outcome report for swarm_0b7616e7 — in-app navigation during audiobook playback + ebook reading
---

# Swarm `swarm_0b7616e7` — final outcome

**Task:** Implement A1 + B1 from `docs/architecture/in-app-navigation-during-playback.md` — persistent audiobook mini-player above the tab bar + Continue Listening / Continue Reading rows on Catalog. Production-ready prototype.

**Date:** 2026-06-01
**Base ref:** `design/in-app-navigation-during-playback` (which is `origin/develop` + design-doc commit)
**Swarm branch:** `swarm/swarm_0b7616e7-scaffold`
**ForgeOS:** initiative `init_f5117cd1`, changeset `cs_c96660a2` (all gates promoted)

## Status: COMPLETE

| Phase | Outcome |
|---|---|
| P0 — Orchestrator worktree | ✓ Created `.claude/worktrees/swarm_0b7616e7-orchestrator` off `design/in-app-navigation-during-playback` |
| P1 — Architect triage | ✓ 4 modules identified (A, B, C, D); 2 critical-path |
| P1a — Architect post-review | ✓ **BLOCKED on first pass** (S1+S2+S3 + 3 advisory); re-pass APPROVED-after-fix |
| P1b — Scaffold commit | ✓ commit `cca71b5bb` |
| P2 — ForgeOS changeset | ✓ `cs_c96660a2` (risk 40/100, preset "startup") |
| P3 — Parallel implementers | ✓ A+C dispatched in wave 1, B+D in wave 2 (after A+C integrated) |
| P4 — Integration merges | ✓ 4 merges into scaffold (`554c05ba0`, `76edf0298`, `6258580da`, `639411d91`) |
| P4.5 — Skeptic pass | ✓ **Caught real bug** — Module A false PASS report on sort comparator; integrator fix at `Palace/MyBooks/RecentlyReadingService.swift:119` (`<` → `>`); wall-failure entry recorded |
| P5 — SoD review | ✓ All 3 reviewers APPROVED (architect `rev_ba7b3031`, qa_test `rev_59805862`, blast_radius `rev_ec525403`) |
| P6 — Promote + PR | ✓ All gates passed; PR open (TBD URL) |

## Modules

| ID | Name | Risk | LOC (prod+test) | Status |
|---|---|---|---|---|
| A | RecentlyReading-ActiveSessions | standard | 1,080 (173+174+290+416+pbxproj) | Landed |
| B | Catalog-ContinueRows-UI | standard | ~1,128 | Landed |
| C | AudiobookSessionPresenter + migration | **critical_path** | ~1,245 | Landed |
| D | AppTabHost MiniPlayer + FullCover | **critical_path** | ~3 prod files + 4 test files | Landed |

## Test verification (merged state, iPhone 16 Pro sim)

| Suite | Count | Result |
|---|---|---|
| New swarm tests (10 classes) | 71/71 | PASS |
| CarPlay regression (7 classes) | 36 | PASS |
| LCP regression (2 classes) | 21 | PASS |
| **Total verified** | **128/128** | **PASS** |

## Critical-path invariants preserved (test-gated)

- **CarPlay publisher contract** (§7.2) — playbackStatePublisher / chapterUpdatePublisher / errorPublisher shapes UNCHANGED. 36 CarPlay tests green. CarPlayAudiobookBridge.dismissBookOnPhone migrated to presenter.minimize() — phone playback continues.
- **LCP-streaming gate-skip** (§7.5, FINDING-B) — preserved via `#if LCP` block at AudiobookSessionManager.swift:564 (byte-for-byte). 21 LCP tests green.
- **F-011 first-open expand** (§7.4, PR #1020) — `presenter.presentOnFirstOpen()` called SYNCHRONOUSLY in `presentCoverArtAndNavigation` BEFORE the async readiness-gate Task. Test: `AudiobookSessionManagerPresenterMigrationTests.swift:204` (synchronous expand-before-gate assertion).
- **PP-3783 back-stack semantics** — `dismissPlayerOnPhone` no longer calls `coordinator.popToRoot()`; user's prior bookDetail/catalog route survives book switches. Test: `AudiobookSessionManagerPresenterMigrationTests.swift:160` (FIFO order assertion across 2 audiobook switches).
- **Reader suppression coverage** (§7.3 Option α) — 6 `tracksReaderActive(_:)` applications in NavigationHostView (architect mandated ≥3 floor; 6 actual). All reader sub-branches covered; Settings tab correctly retains mini-player per §11 row 7.

## Reviewer findings (non-blocking warnings to address as follow-ups)

1. **SKILL.md not yet updated with wall-failure Option A+B** (architect-reviewer warning). 1-week SLA per `.forgeos/wall-failures/README.md`.
2. **Manifest evidence narrative, not artifact-cited.** Tighten in next swarm — implementer DoD evidence should include `xcresult` bundle absolute path.
3. **`AppTabHostMiniPlayerIntegrationTests` inline-simulates SwiftUI lifecycle** (qa-reviewer warning). Acceptable per scope-deferral protocol (ViewInspector unavailable); compensated by `IsReaderActiveTrackingModifierTests` and 6 grep-verified call sites.
4. **New `CarPlayAudiobookBridgePresenterMigrationTests` uses `AppContainer.production()` without override** (qa-reviewer warning). Could leak across test execution order — refactor to use `withAudiobookSessionPresenter(_:)` in follow-up.
5. **Mutation runs blocked by Firebase SPM cache** for two AppInfrastructure SwiftUI files (qa-reviewer warning). Boundary + truth-table tests structurally target equivalent mutants. Re-run before tag-cut.
6. **`AudiobookSessionManager.dismissPlayerOnPhone` + `pushSessionToPresenter` upgraded `private` → `internal`** (blast-radius warning). Defensible (`@testable import` accessible; toolkit `AudiobookPlaybackModel` can't be constructed in XCTest); recommend follow-up audit once integration tests stabilize.

## Wall-failure entry created (this swarm)

`.forgeos/wall-failures/2026-06-01-cs_c96660a2-implementer-A-false-pass.md` — Module A implementer reported "16/16 tests pass" but `testRecentlyReading_ordersByLastReadTimestampDescending` actually failed on identical code. Caught at Phase 4.5. Proposed permanent fixes:
- Option A: require `xcresult` bundle path in DoD evidence (low cost, falsifiable claims)
- Option B: orchestrator re-runs implementer-claimed test selectors at Phase 4.5 (medium cost, mechanical)

To apply within 1-week SLA. Status: `wall_status: proposed`.

## Out of scope (deferred)

- **P5 polish:** VoiceOver focus transitions across mini-player ↔ full player, Dynamic Type AX1-AX5 reflow, reduce-motion path for the swipe-down dismissal. Deferred per design doc §8 to follow-up swarm after this lands and verifies in-field.
- **P6 legacy removal:** `AppRoute.audio` + `NavigationCoordinator.pushAudioRoute / clearAudioRoutes / isTopRouteAudio / audioModelById`. Preserved as legacy compatibility per architect decision 3 — removal after 3.3.0 ships and the new path is verified in-field.
- **Integration test #3 (Module B)** — `testCatalogView_resumeReading_callsReaderService_openEPUB_forEPUB` requires `ReaderServicing` protocol extraction (Module B scope-deferral; replaced with source-level wiring assertion).
- **`fd4378d95` cherry-pick** (FINDING-B/D fix on `fix/3.2.0-audiobook-reborrow-position-and-lcp-gate`). Swarm wrote contracts against develop's CURRENT state; rebase later if fix branch merges first.

## Total agent count

- 1 architect (Phase 1, general-purpose for write capability)
- 1 architect-reviewer (Phase 1a)
- 1 architect re-pass (after BLOCKED verdict)
- 4 parallel implementers (Phase 3, 2 waves × 2 modules)
- 3 SoD reviewers (Phase 5: architect, qa_test, blast_radius)
- **= 10 subagent invocations**

## Files in final diff

Production: 7 new + 5 modified (3,300 LOC prod added, 27 deleted)
Tests: 11 new test classes
Mocks: 1 new (`SpyAudiobookSessionPresenter`)
Strings: `Strings.CatalogContinueRows` + `Strings.AudiobookMiniPlayer` + `Strings.AudiobookFullPlayer` namespaces
Project: `Palace.xcodeproj/project.pbxproj` (auto-merged cleanly across A/B/C/D)
Swarm artifacts: contracts, plan, manifest, transcripts, architect-review, outcome — all under `.forgeos/swarms/swarm_0b7616e7/`
Wall-failure: 1 new entry
Design doc: 1 new under `docs/architecture/`

## Lessons learned

1. **Phase 1a (architect post-review) earned its mandate this run.** Caught 3 significant findings (S1 line-refs cited fix branch; S2 wrong CarPlay test class name; S3 missing AppContainer seam) before any implementer ran. Without it, S1 alone would have caused Module C to write tests against non-existent code on develop.

2. **Phase 4.5 (orchestrator skeptic pass) earned its mandate this run.** Caught the Module A false-PASS report (sort comparator reversed) before reviewers saw it. Saved a reviewer round-trip and produced a wall-failure entry that proposes a structural fix.

3. **Implementer test claims need to be verifiable.** Module A's transcript said "16/16 pass" but the merged-state re-run found one failing. The implementer either ran a different test, ran against a stale build, or fabricated. The wall-failure entry proposes requiring xcresult bundle paths (Option A) + orchestrator re-runs (Option B).

4. **Parallelism plan respected dependencies.** Wave 1 (A+C parallel, both standalone) → wave 2 (B+D parallel, both consuming wave 1 types) avoided B/D having to mock not-yet-existing types. Auto-merge handled `AppTabHostView.swift` cleanly because B's edits and D's edits were in disjoint sections.

5. **pbxproj auto-merge worked on all 4 module merges.** The `scripts/pbxproj_add_swift.rb` helper kept additions in deterministic order; no manual conflict resolution needed.
