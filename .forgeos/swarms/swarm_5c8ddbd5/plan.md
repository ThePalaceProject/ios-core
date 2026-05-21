# Swarm 1 — Audiobook Vendor Adapter Extraction

**Swarm ID:** `swarm_5c8ddbd5`
**Created:** 2026-05-21
**Base:** `origin/develop` @ `ae1fb8aec`
**ForgeOS project:** `proj_87884c17`
**Companion ADR:** `docs/architecture/audiobook-systemic-overhaul.md`

## Goal

Replace the implicit source-shape dispatch in `Palace/Audiobooks/AudiobookLoader.swift` with an explicit `AudiobookVendorAdapter` protocol + four concrete adapters (LCP, LocalFile, BearerToken, OpenAccess), so the OPDS-feed-shape asymmetry that produced PP-4407 (Marketplace audiobook open) becomes a typed contract rather than a property-check tangle.

This is Phase 1 of the 3-phase audiobook systemic overhaul. Earliest start: now. No blocking dependencies on other in-flight worktrees.

## Materially significant deviations from the ADR's proposed partition

1. **The ADR's Module A names a "Findaway adapter" — dropped.** Findaway is toolkit-side (`PalaceAudiobookToolkit/Core/FindawayAudiobook.swift`). The Palace loader does not branch on Findaway; `AudiobookFactory` in the toolkit does. The new partition has **four modules (A/B/C/D) but no Findaway file**.

2. **The ADR puts `AudioBookVendors+Extensions.swift` in Module A's scope. Dropped.** That file does Cantook DRM key refresh, a manifest-content post-processor, not a source-shape dispatcher. Stays untouched in this swarm; the build() method's existing Cantook step works identically after the rewrite.

3. **The ADR's exit criterion "PR #970's OPDS shape matrix passes" — those tests are not in develop.** Module D introduces them as part of the rewrite. The reference in the ADR was aspirational.

4. **The ADR scopes Module C to "conformance only on LCPAudiobooks.swift." Expanded to "conformance + recursive hasLCPAcquisition predicate."** The recursive predicate is the load-bearing fix that catches the Marketplace OPDS shape — without it, the swarm doesn't actually fix PP-4407's regression class. References commit `ca2ff13b6` (3.0.3 hotfix) in code comments.

5. **The ADR's "OpenAccess + Overdrive" Module B becomes "OpenAccess + BearerToken + LocalFile"** — the loader has no Overdrive-specific branch (Overdrive code lives in `Palace/MyBooks/OverdriveDownloadHandler` and presents to the loader as either a local file or a bearer-token fulfill URL). The three adapters carve the loader's three real source shapes cleanly.

## Modules

| Module | Owns | Depends on |
|---|---|---|
| **A** — Adapter protocol | NEW `Vendors/AudiobookVendorAdapter.swift` + tests | nothing |
| **B** — Network adapters | NEW `Vendors/{OpenAccess,BearerToken,LocalFile}Adapter.swift` + tests | A's protocol shape |
| **C** — LCP adapter | MODIFIED `LCP/LCPAudiobooks.swift`, NEW `Vendors/LCPAdapter.swift` + tests | A's protocol shape |
| **D** — Loader dispatch | MODIFIED `AudiobookLoader.swift`, NEW dispatch + OPDS-matrix tests | A, B, C |

## Parallelism plan

- **Phase 3a (1 implementer):** Module A lands first. Protocol is small (~80 LOC + tests).
- **Phase 3b (parallel, 2 implementers):** Modules B and C ship in parallel once A's protocol is committed. No file overlap.
- **Phase 3c (1 implementer):** Module D consumes A+B+C, rewrites the loader, adds the OPDS matrix tests.

Estimated walltime: A=1h, B||C=3h, D=4h. **Total ~8h sequential, ~5h with parallelism on B||C.**

## Disjointness validation (against current code on develop @ ae1fb8aec)

- Module A: NEW files only. No overlap.
- Module B: NEW files only. No overlap with C (different files) or D (D edits AudiobookLoader, B doesn't).
- Module C: MODIFIED `LCPAudiobooks.swift`; B and D don't touch this file. NEW `LCPAdapter.swift` exclusive to C.
- Module D: MODIFIED `AudiobookLoader.swift`; A/B/C don't touch this file.

All four partitions are disjoint at file granularity. No two modules edit the same lines. `AudiobookLoader.swift` is exclusively D's.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Module D's rewrite collides with in-flight uncommitted bugfix worktrees on AudiobookSessionManager | SessionManager is in the don't-touch list. D only edits Loader. Confirmed: SessionManager calls `AudiobookLoader().load(book:)` at line 321; `load()` signature is frozen. |
| Recursive hasLCPAcquisition is wrong on some real-world OPDS fixture not in our suite | The PP-4407 fixture (Marketplace, demo.thepalaceproject.org/GA0000) goes in the matrix as the explicit regression gate. Follow-up swarms add rows. |
| Module C's LCPAdapter breaks Palace-noDRM | LCPAdapter wraps its entire body in `#if LCP`. Adapter chain in loader skips LCPAdapter in non-LCP builds. |
| Module B's adapters duplicate `AppContainer.production()` reads | Constructor-style DI mandated by contract — adapters take collaborators through init. AppContainer reads stay in adapter-array construction inside the loader. |
| Module D's two-stage rewrite is risky to merge as one | Existing `AudiobookLoaderTests` + `AudiobookLoaderPredicateTests` gate Stage 1 (consolidation). Stage 2 (route through adapter chain) is gated by the new dispatch + OPDS matrix tests. |

## Acceptance criteria (gate for promotion)

- All four contract files' acceptance criteria met (≤200 LOC per adapter, 100% mutation kill rate per `palace_mutate.py --diff-only`)
- `scripts/verify-pr.sh --quick` passes
- `AudiobookLoader.swift` LOC reduces ≥30% vs `ae1fb8aec`
- OPDS shape matrix tests include the explicit PP-4407 fixture and the property-check-would-have-failed assertion
- `LCPAcquisitionPredicateTests` covers the recursive walk with a comment referencing commit `ca2ff13b6` (3.0.3 hotfix)
- `mcp__forgeos__forge_check_gates` shows all SoD reviewers satisfied (architect, qa_test minimum)
- No edits to any file in the swarm-wide don't-touch list

## Swarm-wide don't-touch list

- `PalaceTests/Audiobook/AudiobookPositionPolicyTests.swift` (uncommitted in main)
- `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` (uncommitted in main)
- `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` (uncommitted in main)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (Swarm 3 territory)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (Swarm 3 territory)
- `Palace/Audiobooks/Tracker/*` (Swarm 2 territory — PositionWriter)
- `Palace/CarPlay/*` (PR #968 territory)
- `ios-audiobooktoolkit/` submodule (parallel toolkit workstream)
- `Palace/Audiobooks/AudioBookVendors+Extensions.swift` (out of swarm scope)
- `Palace/Audiobooks/AudioBookVendorsHelper.swift` (out of swarm scope)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (Module C2 follow-up only)

## Architect surprises (preserved from triage transcript)

1. **No Findaway branching in Palace.** Confirmed by `grep -ri findaway Palace/Audiobooks/` returning zero hits.
2. **No Overdrive branching in the loader.** Overdrive fulfillment is in `Palace/MyBooks/OverdriveDownloadHandler.swift`. By the time the loader runs, Overdrive looks identical to OpenAccess.
3. **`hasLCPAcquisition` doesn't exist on develop.** The 3.0.3 hotfix added it on the release branch; not forward-merged to develop. Module C introduces it.
4. **PR #970 OPDS shape matrix doesn't exist** in develop. Module D authors fresh.
5. **Dispatch is spread across TWO methods** in AudiobookLoader (`resolveManifestAndDecryptor` lines 142-219 and `fetchOpenAccessManifest` lines 346-396). Module D needs a two-stage rewrite in one PR.
6. **AudiobookSessionManager is the only caller of the loader's public surface** (line 321). Keeping `load(book:completion:)` signature stable means SessionManager (in don't-touch) compiles unchanged.
7. **PP-4407 hotfix code (symlink recovery) is NOT in develop's loader.** The swarm intentionally does NOT re-introduce symlink recovery — the adapter pattern + recursive `hasLCPAcquisition` makes it unnecessary because the LCP adapter routes Marketplace books to the LCP loader chain directly, never falling through to the JSON-parse-on-binary path that needed symlink recovery.

<!-- audit-verified: 2026-05-21 — architect triage report grounded in current-worktree code reads (AudiobookLoader.swift line numbers, hasLCPAcquisition absence from develop verified, PR #968 + #967 merge status confirmed earlier in session). -->
