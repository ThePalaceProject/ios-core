---
name: swarm_f4fbef9c-plan
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [general]
description: Swarm 2 — PositionWriter Unification
---

# Swarm 2 — PositionWriter Unification

**Phase 2 of [audiobook-systemic-overhaul](../../../docs/architecture/audiobook-systemic-overhaul.md).**

Companion to Swarm 1 (`swarm_5c8ddbd5`, PR #979 open). Disjoint partition — Swarm 1 owned `Palace/Audiobooks/Vendors/*` + `AudiobookLoader.swift`; this swarm owns `Tracker/*`, `Palace/Reader2/BusinessLogic/TPPLastReadPosition*.swift`, and a new SPM package `PalaceReadingPosition`.

## Problem (recap from ADR pattern #4)

Position-write logic is duplicated across three sites with subtly different server contracts:

| Site | LOC | Contract |
|---|---:|---|
| `Tracker/AudiobookDataManager.swift` | 345 | Network sync; uses `syncQueue`; UIApplication background tasks |
| `AudiobookPositionPolicy.swift` | 243 | Restoration/fallback selection (read-side) |
| `LatestAudiobookLocation.swift` | 19 | Local cache model |
| `Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | (existing) | EPUB; serialQueue + Date-based throttle |
| `Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` | (existing) | EPUB; load + conflict-merge |

The toolkit calls Palace via `AudiobookBookmarkDelegate` (defined in `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookManager.swift:31`). The audiobook side then delegates to `AudiobookDataManager`. The EPUB side uses `TPPLastReadPositionPoster` directly. **The server contract differs subtly** between these two paths — same endpoint shape, different serialization fields. That asymmetry is the latent failure surface.

`swarm_f3b9b087` (P0 position correctness merged 2026-05-20, commit `520573305`) was Phase-0-equivalent groundwork. This swarm is the *structural* fix.

## Decision

Single `PositionWriter` protocol in a new `PalaceReadingPosition` SPM module. **One canonical implementation.** Audiobook + Reader2 EPUB + PDF all write through it.

## Module partition (must be disjoint — verified)

| Module | Owner files (exclusive write) | Depends on |
|---|---|---|
| **A** — `PalaceReadingPosition` SPM | NEW `Palace/Packages/PalaceReadingPosition/Package.swift`, `Sources/PalaceReadingPosition/{PositionWriter.swift, CanonicalPositionWriter.swift, PositionSnapshot.swift, PositionWriterError.swift}`; NEW `Tests/PalaceReadingPositionTests/*` | — |
| **B** — Audiobook-side migration | MOD `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (delete network sync; delegate); MOD `Palace/Audiobooks/Tracker/AudiobookTimeTracker.swift`; DELETE `Palace/Audiobooks/LatestAudiobookLocation.swift`; MOD audiobook-side callers | A |
| **C** — Reader2 + PDF migration | MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift`; MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift`; MOD PDF position-write call sites | A |
| **D** — Contract-snapshot tests | NEW `PalaceTests/Contract/PositionWriterContractTests.swift` + `__Snapshots__/`; NEW `PalaceTests/Contract/AudiobookPositionAdapterContractTests.swift`; NEW `PalaceTests/Contract/Reader2PositionAdapterContractTests.swift` | A, B, C |

**Disjointness check:**
- A owns the SPM package — no other module writes there
- B owns the `Tracker/` directory + `LatestAudiobookLocation.swift` only
- C owns `Reader2/BusinessLogic/TPPLastReadPosition*.swift` only
- D owns `PalaceTests/Contract/` only
- The `AudiobookPositionPolicy.swift` (243 LOC, read-side restoration) is **read-only** for this swarm — its tests don't touch network and it's not on the write path

## Don't-touch (cross-swarm hygiene)

- `Palace/Audiobooks/Vendors/*` (Swarm 1 territory, PR #979 open)
- `Palace/Audiobooks/AudiobookLoader.swift` (Swarm 1)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (Swarm 3 territory)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (Swarm 3)
- `Palace/Audiobooks/Tracker/AudiobookTimeEntry.swift` (read-only — used by B's migration but not modified)
- `ios-audiobooktoolkit/` (toolkit submodule — parallel T1 workstream, NOT this swarm)
- `Palace/CarPlay/` (PR #968 settled territory)
- `Palace/Audiobooks/AudiobookPositionPolicy.swift` (read-side restoration; not on write path)

## Acceptance gates

1. **Day-1 consumer rule** — Module B AND Module C migrate in the same PR as Module A. No "SPM module shipped, adoption deferred" antipattern (PR #936 retro lesson).
2. **All 3 prior position writers either removed or routed through `PositionWriter`** — `git grep "lastReadPositionUploadDate\|LatestAudiobookLocation" Palace/Audiobooks Palace/Reader2 --include='*.swift'` should return 0 outside the new SPM module.
3. **Contract snapshot locked** — `PalaceTests/Contract/__Snapshots__/PositionWriterContractTests/` directory exists with at least 3 named scenarios (save-throttle, load-cache-hit, load-cache-miss-fetch).
4. **≥80% mutation kill rate on `CanonicalPositionWriter`** — `palace_mutate.py --diff-only --file Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/CanonicalPositionWriter.swift`.
5. **All existing position tests continue to pass** — `PositionSyncTests.swift`, `TPPLastReadPositionSynchronizerTests.swift`, `TPPLastReadPositionPosterTests.swift`, `AudiobookPositionPolicyTests.swift`, `PositionSyncServiceTests.swift`, `ReadingPositionTests.swift`.
6. **`AudiobookBookmarkDelegate` toolkit-side surface unchanged** — toolkit submodule stays unmodified; Palace-side `AudiobookSessionManager.swift:[delegate impl line]` adapter still satisfies the protocol.
7. **No edits in don't-touch list** — `git diff origin/develop -- <don't-touch paths>` returns empty.

## Architect triage requirement

Before dispatch, an architect agent reads:
- This plan + the ADR section "Pattern 4: Position writers don't share a contract"
- The 5 active position files (line counts above)
- `swarm_f3b9b087`'s commit `520573305` to understand what's already been corrected
- `AudiobookBookmarkDelegate` in the toolkit submodule
- The 4 existing tests that touch `AudiobookDataManager.syncQueue`
- `PalaceTests/Platform/ReadingPositionTests.swift` + `PositionSyncServiceTests.swift` to check for naming/protocol collisions with the new SPM module

The architect's deliverable: refined `contracts/{A,B,C,D}.md` with any material deviations from this plan flagged before implementation.

## Swarm methodology lessons applied (from Swarm 1)

1. **Implementer prompts ask for transcripts EARLY** — Swarm 1 had 2 stream timeouts at the transcript-write step. New prompt template asks implementers to write the transcript skeleton FIRST, fill in details before timing out.
2. **Architect triage caught 5 material errors in Swarm 1** — keep the validation step. Don't skip it on the grounds that "the ADR is fresh."
3. **`audit-before-assert` hook** — fires on edits to `docs/architecture/`. ADR was already verified for Swarm 1; this swarm doesn't add new ADRs unless triage uncovers a structural deviation.
4. **Worktree submodule symlinks** — already done via `git worktree add` (Carthage, submodules carry over). Verify before dispatch.

## Predicted timeline

Architect triage: 15-20 min wallclock
Modules A+B+C parallel: 60-90 min wallclock (B and C depend only on A's protocol — they can start as soon as A's `PositionWriter.swift` is on disk; architect contracts can frontload the protocol shape so B/C don't actually block on A's full impl)
Module D: 30-45 min
Integrator: 30-45 min (verify + commit + push + PR)

Total: ~3-4 hours orchestrator wallclock, matching Swarm 1.
