# Swarm 9d3d2fab — CI-flake migration (Phase 1)

## Goal

Eliminate the 63 FLAKE-* violations detected by the linter landed in Phase 0
(commit 9c0eaf7d5 on this same `swarm/swarm_9d3d2fab-scaffold` branch).
Each violation is one of:

- **FLAKE-001**: raw `Thread.sleep` / `usleep` / `nanosleep` / `sleep()` —
  6 sites.
- **FLAKE-002**: `asyncAfter` closure whose only body is
  `<exp>.fulfill()` (the banned "sleep disguised as expectation") —
  30 sites.
- **FLAKE-003**: `timeout: N` with N≥15s, almost always symptomatic of a
  hidden FLAKE-002 or real I/O — 27 sites.

Plus a sister sweep: 16 `URLSession.shared.downloadTask(with:)` sites in
`PalaceTests/MyBooks/` get migrated to `fakeDownloadTask()` (helper added
in Phase 0).

## Migration patterns (apply uniformly)

1. **asyncAfter+fulfill → drainMainQueue OR awaitCondition.**
   - Main-queue work: `drainMainQueue()`. Reason: DispatchQueue.main is
     FIFO, so all earlier-queued blocks have run by the time the no-op
     fulfill fires — zero fixed delay.
   - `Task { ... }`-based async: `awaitCondition(timeout: 5) { <predicate> }`.
     Reason: Tasks don't hop the main queue, so drainMainQueue misses them.

2. **Thread.sleep / usleep → XCTestExpectation driven by real signal**,
   OR `awaitCondition`/`awaitConditionAsync` polling the actual state the
   sleep was trying to settle.

3. **Timeouts ≥15s**: drop to ≤5s once the FLAKE-002 fix removes the need.
   If genuinely integration-test scoped (real disk I/O, large corpus),
   add `// FLAKE-003-OK: <one-sentence reason>` on the same line.

4. **URLSession.shared.downloadTask → fakeDownloadTask()** from the helper
   landed in Phase 0 (`PalaceTests/XCTestCase+fakeDownloadTask.swift`).

## Verification

Each module implementer must, before reporting done:
1. `python3 scripts/lint-test-quality.py --per-file --file <scoped-file>`
   returns zero `:(FLAKE|MISSING|FLUFF|TIMEOUT)-` lines.
2. `xcodebuild test -only-testing:PalaceTests/<TestClassName>` passes for
   each migrated test file.
3. No production code changes (Palace/* off-limits).

Integrator (main agent) runs `verify-pr.sh --quick` after all 6 implementers
return. Net result: linter reports 0 blocking violations.

## Module scope summary

| Module | Files | FLAKE-001 | FLAKE-002 | FLAKE-003 | URLSession |
|--------|-------|-----------|-----------|-----------|------------|
| A — Audiobook | 5 | 0 | 5 | 1 | 0 |
| B — MyBooks | 5 | 1 | 5 | 0 | 16 |
| C — Accounts/SignIn | 8 | 2 | 7 | 4 | 0 |
| D — Holds/BookDetail/Catalog | 5 | 0 | 4 | 6 | 0 |
| E — Network/Errors/Utilities | 8 | 2 | 9 | 11 | 0 |
| F — Integration/Reader2/BookRegistry | 6 | 1 | 2 | 6 | 0 |

Total: 63 FLAKE-* + 16 URLSession sweep.

## Non-goals (do not touch)

- SHALLOW-001 backlog (218 tests) — Phase 4 follow-up.
- UserDefaults.standard writes — Phase 2.
- Singleton `.shared` audit beyond test-helper reset paths — Phase 2.
- New tests added for coverage — pure migration only.
- Any `Palace/*` (production) file. Tests-only PR.

## Risk profile

LOW — mechanical migration, helper exists, linter gates the result.
Risk surface:
- Wrong migration choice (e.g. `drainMainQueue` where `awaitCondition` is
  needed for Task-based async) → caught by per-file test run.
- A 30s timeout that's genuinely needed (large corpus) → mitigated by
  FLAKE-003-OK allow-list with documented reason.

## Acceptance criteria

- `python3 scripts/lint-test-quality.py --per-file | grep -cE ':(FLAKE|MISSING|FLUFF|TIMEOUT)-'` returns 0 (modulo MISSING-001-OK and FLAKE-003-OK allow-listed sites).
- `scripts/verify-pr.sh --quick` passes.
- ForgeOS initiative `init_319cce78`, new Phase 1 changeset proposed.
