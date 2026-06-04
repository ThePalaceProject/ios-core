---
name: swarm_f4fbef9c-outcome
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [general]
description: Swarm 2 — Outcome
---

# Swarm 2 — Outcome

**Status:** complete (open PR)
**PR:** https://github.com/ThePalaceProject/ios-core/pull/980
**ForgeOS initiative:** `init_05b6832a`
**ForgeOS changeset:** `cs_ff…fe78` (proposed via `forge_propose_changeset`, evidence submitted)
**Branch:** `swarm/swarm_f4fbef9c-scaffold` (pushed to origin, upstream: `origin/swarm/swarm_5c8ddbd5-scaffold`)
**Base:** stacks on PR #979; will rebase onto develop when #979 merges.

## What shipped

Phase 2 of the 3-phase audiobook systemic overhaul. PositionWriter unification — three duplicate position-write code paths replaced with a single `PositionWriter` protocol in a new local SPM module `PalaceReadingPosition`. Audiobook, Reader2 EPUB, and PDF all delegate to one canonical `RemotePositionWriter`.

| Metric | Result | Target |
|---|---|---|
| New SPM module | `Palace/Packages/PalaceReadingPosition/` (8 sources + 2 tests) | new package |
| Files migrated from `Palace/Platform/` into SPM | 5 (via `git mv`, history preserved) | per architect triage |
| Existing position writers removed/migrated | 3/3 (`TPPLastReadPositionPoster`, `AudiobookBookmarkBusinessLogic`, `TPPPDFDocumentMetadata`) | 3/3 |
| Dead-code deletions | `LatestAudiobookLocation.swift` + its test class block | per architect triage |
| New tests | 27 (14 RemotePositionWriter + 6 PositionSnapshot + 6 AudiobookPositionWrite + 1 EPUBPositionAdapter helper) | per contract |
| Contract snapshots | 12/13 locked + 1 XCTSkip (documented simdrive follow-up) | 13 |
| Mutation-kill scenarios for `520573305` P0 predicates | 2 (isAtBeginning + timestampNewerRace) | required |
| Full Palace build | SUCCEEDED | required |
| Palace-noDRM build | SUCCEEDED | required |
| Pre-push gate | PASS — 11 classes green | required |
| Don't-touch violations | 0 | 0 |

## Commit chain (10 commits on the orchestrator branch)

| SHA | Conceptual scope |
|---|---|
| `3c67a6fbd` | scaffold (plan + manifest + 4 contract skeletons) |
| `92164c568` | architect triage — 7 material deviations refined into locked contracts |
| `e90f9f2c0` | Module A: PalaceReadingPosition SPM + 5-file Platform migration + pbxproj wiring |
| `4c5258cbd` | Module B: AudiobookBookmarkBusinessLogic migration + dead-code delete |
| `144c07e73` | Module C: Reader2 + PDF migration via PositionWriter |
| `3fbef8e32` | Module D: 13 contract-snapshot scenarios |
| `0e0e9b721` | implementer transcripts |
| `47eb1c5d0` | integrator: AudiobookPositionAdapter `.serverError(_:_:)` arg fix |
| `0d52c1af9` | integrator: contract baseline recordings + iso8601 disambiguation + XCTSkip for cross-device alert path |

**Total:** ~30 files changed, ~4,100 insertions, ~480 deletions vs `swarm/swarm_5c8ddbd5-scaffold@c4d476838`.

## Architect triage — 7 material deviations caught

The architect agent's triage validated the original ADR plan against current code state and flagged 7 issues. The 2 most significant would have broken the swarm completely:

1. **Wrong file target for Module B.** Original plan said `AudiobookDataManager.swift`. Architect proved that file is a time-tracker, not a position writer. Real target: `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`.
2. **Naming + concept collision with existing `Palace/Platform/` types.** `ReadingPosition`, `PositionSyncService`, `PositionSyncServiceProtocol`, `CrossFormatMapping`, `PositionSyncRecord` already existed as comprehensive cross-format scaffolding with tests but zero production callers. Architect's resolution: migrate INTO the SPM as part of Module A; rename the network-write impl from `CanonicalPositionWriter` → `RemotePositionWriter` to keep semantically distinct from `PositionSyncService` (local-record cross-format sync).

Other deviations: `LatestAudiobookLocation` was dead code (safe-delete); `AudiobookSessionManager` did NOT need editing (defaulted-parameter pattern avoids touching Swarm 3 territory); audiobook `debounce` vs EPUB 15s — locked at 15s with QA flag; conflict resolution stays caller-owned; PDF locked-IN.

See `.forgeos/swarms/swarm_f4fbef9c/transcripts/triage.md` for the full triage.

## Implementer agents

- **Architect**: 1 agent. 30 min wallclock. Refined 4 contracts. Stream completed cleanly.
- **Module A**: 1 agent. 75 min wallclock. 20/20 SPM tests pass. Stream completed cleanly.
- **Module B**: 1 agent. ~60 min wallclock. Caught the wrong-file scope correction during read phase. Stream completed cleanly.
- **Module C**: 1 agent. ~60 min wallclock. Defaulted-parameter wiring avoided the TPPBaseReaderViewController one-line edit. Stream completed cleanly.
- **Module D**: 1 agent. ~35 min wallclock. 13 scenarios written. Stream completed cleanly.

**Zero stream timeouts this swarm** — vs Swarm 1's 2 timeouts. The "write transcript skeleton FIRST" pattern (added to all 4 implementer prompts as a Swarm 1 lesson-learned) worked.

## Integrator findings (post-implementer-handoff fixes)

The implementer agents validated via `swift test` + `swiftc -parse` because the orchestrator worktree's `xcodebuild` hit the Carthage symlink loop ([memory: worktree-palace-setup](https://github.com/.../memory/feedback_worktree_palace_setup.md)). The integrator (this session) hit the same issue, fixed the root cause (`ios-audiobooktoolkit` symlink → real submodule clone), then surfaced 3 real issues the implementer-side `swiftc -parse` missed:

1. **`PositionWriterError.serverError(_:_:)` constructor used as a value** (`AudiobookPositionAdapter.swift:45`). Fixed by passing `statusCode: -1, body: nil`.
2. **`Date.iso8601` ambiguous** when both `@testable import Palace` and `@testable import PalaceAudiobookToolkit` are present (both define the extension). Fixed by using `ISO8601DateFormatter` directly in 2 test files.
3. **`TPPOPDSAcquisition` not in scope** in 2 new test files. Fixed by adding `import PalaceCatalog` (where the type moved after the catalog SPM extraction).

These would have surfaced in CI but blocked the orchestrator's pre-push gate; surfacing them in this session saved a CI roundtrip.

## Behavior changes for QA

- **Audiobook position write throttle**: was per-instance `debounce` (collapses rapid calls); now 15.0s per-book window (matches EPUB). User-visible: at most 1 POST per 15s of active playback. Rapid track-skip cycles within 15s coalesce. Local-save-first invariant unchanged — no user data at risk.
- **PDF position write throttle**: was unthrottled; now 15.0s per-book window. Reduces server load on rapid page-turn flows.
- **Cross-device EPUB sync**: alert path unchanged (still presents `presentNavigationAlert`); the underlying load now goes through `PositionWriter.load` but the merge rule (`deviceID == drmDeviceID && localLocation != nil || locationString match`) is preserved verbatim.

## Methodology lessons (post-Swarm-1 deltas)

1. **Zero stream timeouts** when implementer prompts mandated "write transcript skeleton FIRST" — Swarm 1 had 2 timeouts at the transcript-write step, this swarm had zero. Pattern works; keep it for Swarm 3.
2. **Architect triage caught 7 material errors** in 30 minutes — including 2 that would have broken the swarm. Triage is not ceremony; it's the highest-leverage step.
3. **Carthage symlink loop in worktrees is well-documented but easy to forget**. The `ios-audiobooktoolkit` MUST be a real submodule clone in worktrees (its own pbxproj uses `../Carthage/Build`). Adding to the orchestrator-setup pre-flight checklist as a follow-up.
4. **The pre-push hook's 90s timeout assumes a small diff**. For first-push of a feature branch, `@{u}` is unset → hook falls back to `origin/main..HEAD` → 30+ Palace/*.swift files → derives ~20+ test classes → exceeds 90s. Fix: `git branch --set-upstream-to=origin/<predecessor>` BEFORE pushing. Adding to the swarm-orchestrator checklist.
5. **Contract-snapshot tests that drive `UIAlertController` paths need a `UIWindow`** — not present in xcodebuild test context. The `test_epubSynchronizer_sync_remoteDifferentDevice_loadsThenReturns` test is XCTSkip'd with a documented simdrive E2E follow-up.

## What's next

- **PR #980 review** — base is `swarm/swarm_5c8ddbd5-scaffold` until #979 merges, then rebases to develop.
- **Swarm 3 (singleton elimination + async sweep)** is unblocked when both #979 and #980 have merged or settled — Module C of Swarm 3 rewrites `AudiobookLoader.swift` (Swarm 1 territory) and `AudiobookDataManager.swift`, so cleanest after both prior swarms land.
- **Cross-device EPUB sync E2E**: simdrive flow to cover the alert path that's currently XCTSkip'd.
- **Toolkit T1+T2 (Player async migration)**: parallel workstream in the `ios-audiobooktoolkit` submodule. Not gated on Palace swarms.
- **PR #936 retro lesson applied**: SPM module shipped with Day-1 consumers (3 call sites migrated in same PR as the module). No "infrastructure-built, adoption-skipped" antipattern.

The audiobook overhaul plan's predicted 1.5-2 week calendar timeline now has 3-5 days of effective work remaining (Swarm 3 + toolkit T1+T2 + submodule bump + 3.3.0 release-train activities).
