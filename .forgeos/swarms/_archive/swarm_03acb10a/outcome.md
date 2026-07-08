---
name: swarm_03acb10a-outcome
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [general]
description: Swarm 3 — Outcome
---

# Swarm 3 — Outcome

**Status:** complete (open PR)
**PR:** https://github.com/ThePalaceProject/ios-core/pull/982
**ForgeOS initiative:** `init_eb359cf0`
**ForgeOS changeset:** `cs_3c089d95`
**Evidence:** submitted via `forge_submit_evidence` (test summary)
**Branch:** `swarm/swarm_03acb10a-scaffold` (pushed to origin, upstream: `origin/swarm/swarm_f4fbef9c-scaffold`)
**Base:** stacks on PR #980 (which stacks on PR #979); will rebase onto develop when both merge.

## What shipped

Phase 3 of the 3-phase audiobook systemic overhaul — and the final Palace-side phase of the plan. `static let shared` removed from both audiobook singletons; the 4 production call sites + 5 test files migrated to construct instances via `AppContainer.production().audiobookSession` / `.playbackBootstrapper`. `DispatchQueue.main.asyncAfter` swept from `NowPlayingCoordinator.swift`. ~106 LOC of obsolete test workarounds deleted.

| Metric | Result | Target |
|---|---|---|
| `static let shared` in `Palace/Audiobooks/` | **0** | 0 |
| `.shared` callers outside AppContainer.swift | **0** | 0 |
| `DispatchQueue.main.asyncAfter` in `Palace/Audiobooks/` (excluding comments) | **0** | 0 |
| Production call sites migrated | 4 (TPPAppDelegate, CarPlaySceneDelegate, BookService, CarPlayAudiobookBridge) | 3+ |
| AppContainer factory LOC added | 31 | ≤80 |
| Test files modified | 5 | per inventory |
| New tests | 3 (AppContainerAudiobookFactoryTests) | per contract |
| Net LOC delta | **−106** | net-negative |
| AudiobookLoader.swift LOC | **418 (unchanged)** | unchanged or smaller |
| Full Palace build | SUCCEEDED | required |
| Palace-noDRM build | SUCCEEDED | required |
| New + migrated tests | **129/129 PASS** (3 + 37 + 89) | required |
| Pre-push gate | PASS | required |
| Don't-touch violations | **0** | 0 |
| Stream timeouts | **0** | 0 |

## Commit chain (7 commits on the orchestrator branch)

| SHA | Conceptual scope |
|---|---|
| `bb6d92cef` | scaffold (plan + manifest + 4 contract skeletons) |
| `4862c136c` | architect triage — 8 material deviations refined into locked contracts |
| `85909d6f3` | AppContainer cached factories + 3 new tests |
| `0659f576e` | Delete `.shared` singletons + 4 production call-site migrations + test-file migrations |
| `abfcb2893` | NowPlayingCoordinator `asyncAfter` → `Task.sleep` |
| `7311064de` | Test cleanup: delete dead-API class + redundant setUp resets (-106 LOC) |
| `(transcripts)` | implementer transcripts (internal) |

**Total:** ~17 production/test files changed, ~210 insertions, ~316 deletions vs `swarm/swarm_f4fbef9c-scaffold@52e99443f`.

## Architect triage — 8 material deviations caught

1. **AppContainer is a struct, no per-account pattern from PR #967.** Module A drops per-account caching entirely; mirrors `_bookCellModelCache` pattern.
2. **AudiobookSessionManager already has `convenience init(appContainer:)` at line 212.** Module B's migration is mostly deletion — drop `static let shared` + parameterless seed convenience.
3. **PlaybackBootstrapper already has `audiobookSessionProvider` seam at line 101.** Module B just drops the default closure value.
4. **`BookService.openBook` is `static`.** Call-site edit uses `AppContainer.production()` direct read, not `self.appContainer`.
5. **AudiobookDataManager DROPPED from Module C.** Its `syncQueue.async(flags: .barrier)` is a deliberate prior fix REPLACING `DispatchQueue.main.asyncAfter`; migrating it back would reverse a flakiness-elimination fix. Module C scope reduced to ONE file: `NowPlayingCoordinator.swift`.
6. **NowPlayingCoordinator workItem migration locked.** Field type `DispatchWorkItem?` → `Task<Void, Never>?`; both `CancellationError` catch AND `Task.isCancelled` check preserve the prior cancel semantic.
7. **`AudiobookReliabilityTests.swift` references 7 dead-API methods.** The methods exist on `PalaceAudiobookToolkit.AudiobookSessionManager` (toolkit submodule), NOT on `Palace.AudiobookSessionManager` — fragile cross-package coverage. Deletion stands.
8. **`CarPlayTests.swift` has the same dead-API issue** (`clearAllState()` at lines 23, 28). Module D removes those calls.

See `transcripts/triage.md` for the full triage.

## Implementer agents

- **Architect**: 1 agent. ~45 min wallclock. Refined 4 contracts. Caught the 5th file build-error in advance (CarPlayAudiobookBridge would have surfaced at integrator stage; architect didn't pre-flag but Module B surfaced and fixed it cleanly).
- **Module A**: 1 agent. 3/3 tests pass. Stream completed cleanly.
- **Module B**: 1 agent. Surfaced + fixed CarPlayAudiobookBridge.swift (out-of-contract; switched field type from concrete class to protocol) + AudiobookOpenStateRaceTests.swift. 37/37 tests pass. Stream completed cleanly.
- **Module C**: 1 agent. NowPlayingCoordinator workItem→Task migration. grep gates pass. Stream completed cleanly.
- **Module D**: 1 agent. -106 LOC. 89/89 sibling tests pass. Found that "dead-API" methods exist on toolkit-side (not Palace-side) — re-rationalized the deletion. Stream completed cleanly.

**Zero stream timeouts** this swarm — same as Swarm 2 (vs Swarm 1's 2). The skeleton-first pattern + tighter architect contracts work.

## Integrator findings

Modules A and C had bootstrapped the orchestrator worktree's submodules via `cp -R` (real-dir copies) which broke `git status` (the copied dirs had no `.git` entries pointing back into `.git/modules/`). Integrator (this session) replaced the broken real-dir copies with symlinks to the main checkout's submodules (per memory `feedback_worktree_palace_setup.md`), then `git submodule update --init` for `ios-audiobooktoolkit` to get it as a real submodule. Worktree usable; both builds clean.

No code-level integrator fixes needed — Modules A/B/C/D shipped clean compilable code that passed all gates.

## Methodology lessons (post-Swarm-2 deltas)

1. **Pre-triage recon is high-leverage.** Plan-stage recon surfaced significantly smaller scope than the ADR predicted — Swarm 1 absorbed the callback-pyramid work; only 1 `asyncAfter` remained. Architect then validated. This saved Module C from being scoped to multi-file work it didn't need to do.
2. **Architect's defaulted-parameter pattern continues to work.** Module B's migration used defaulted-parameter shapes on the singleton classes so the 4 production call sites became single-line edits. Pattern proven 3 times now (Swarm 1, Swarm 2, Swarm 3).
3. **Worktree submodule setup is a recurring tax.** Module A and C agents both took workspace-fix detours. Updating `feedback_worktree_palace_setup.md` memory to explicitly tell future agents: "use the integrator's symlinks-to-main approach, not `cp -R`".
4. **The pre-push hook scales nicely** once the upstream is set to the predecessor swarm — only Swarm 3's diff (9 changed `Palace/*.swift` files, 11 derived test classes) goes through the 90s gate. Same pattern as Swarm 2.
5. **Module D's value isn't always test cleanup.** Two of the 5 files Module D touched were dead-API cross-package coverage that should have been deleted long ago. The swarm exposed this as a side effect of the singleton elimination.

## What's next

- **PR #982 review** — base is `swarm/swarm_f4fbef9c-scaffold` until PR #980 merges, then rebases.
- **All 3 Palace-side swarms now have open PRs**:
  - PR #979 (Swarm 1 — vendor adapters)
  - PR #980 (Swarm 2 — PositionWriter)
  - PR #982 (Swarm 3 — singleton elimination)
- **Toolkit-side T1+T2 (Player async)**: independent workstream in `ios-audiobooktoolkit` submodule. Not gated on Palace merges.
- **Toolkit T3 (rename `AudiobookSessionManager` → `AudiobookDownloadCoordinator`)**: now that Palace has only ONE `AudiobookSessionManager` (the toolkit's), the rename can land in the toolkit without naming collision.
- **3.3.0 release-train activities**: post-merge.

The audiobook overhaul plan's predicted 1.5-2 week calendar timeline is now executed (3 Palace swarms shipped). Remaining work is toolkit-side + release-train, not architectural.
