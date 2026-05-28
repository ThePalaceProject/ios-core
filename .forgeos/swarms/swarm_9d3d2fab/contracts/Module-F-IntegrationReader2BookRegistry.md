---
name: swarm_9d3d2fab-contract-Module-F-IntegrationReader2BookRegistry
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-22
freshness_window: never
owners: [reader]
description: Module F — Integration/Reader2/BookRegistry (CI-flake migration)
---

# Module F — Integration/Reader2/BookRegistry (CI-flake migration)

## Files in scope (6)

| Path | FLAKE-001 | FLAKE-002 | FLAKE-003 |
|------|-----------|-----------|-----------|
| PalaceTests/Integration/ColdStartResumeIntegrationTests.swift | — | — | L84 (120s — integration test) |
| PalaceTests/AppInfrastructure/AppContainerImageLoaderInjectionTests.swift | — | L86 | L102 (30s) |
| PalaceTests/BookRegistry/TPPBookRegistryAtomicWriteTests.swift | L259 (usleep 2ms) | — | L102, L275 (30s) |
| PalaceTests/BookRegistry/TPPBookRegistryLargeCorpusTests.swift | — | — | L108 (120s default), L207 (60s) |
| PalaceTests/BookRegistry/TPPBookRegistryPersistenceTests.swift | — | — | L105 (30s) |
| PalaceTests/BookRegistry/TPPBookRegistryMigrationTests.swift | — | — | L85 (30s) |

Authoritative: `python3 scripts/lint-test-quality.py --per-file --file <path>`.

## Migration patterns

Standard. Specific guidance (this module has the most legitimate FLAKE-003-OK candidates):

- **ColdStartResumeIntegrationTests.swift L84 (120s)**: this is the cold-start integration test that walks the app from launch through restore-state. Read the test body. If it's a real integration test exercising disk I/O + bookshelf hydration + position resume, FLAKE-003-OK is correct. Add `// FLAKE-003-OK: cold-start integration test — bookshelf hydration + position-resume round-trip touches real disk + registry rebuild, 120s budget covers CI contention.` on the same line. Drop to 30s if the bulk was just padding.

- **TPPBookRegistryLargeCorpusTests.swift (L108: 120s default, L207: 60s)**: large-corpus tests load thousands of book records from disk to verify the registry's atomic-write pipeline. The corpus size justifies the time. FLAKE-003-OK with documented reason.

- **TPPBookRegistryAtomicWriteTests.swift L259 (`usleep(2_000)` = 2ms)**: the comment says it's to "let the OS schedule" between concurrent writes. The 2ms IS the contention window. Replace with `await Task.yield()` (gives the scheduler the same opportunity without a fixed-time sleep), OR with an `XCTestExpectation` driven by the writer's completion callback.

- **TPPBookRegistryAtomicWriteTests.swift (L102, L275 — 30s timeouts)**: atomic-write contention tests; the timeout was set high "just in case". Drop to 10s — if the test legitimately needs 30s, the implementation is too slow.

- **TPPBookRegistryPersistenceTests.swift L105, TPPBookRegistryMigrationTests.swift L85 (30s)**: persistence/migration round-trips. 30s → 10s should work; if not, FLAKE-003-OK with reason.

- **AppContainerImageLoaderInjectionTests.swift (L86 asyncAfter+fulfill, L102 30s)**: the asyncAfter at L86 is paired with the 30s wait at L102. Fix the asyncAfter (drainMainQueue), then drop L102's timeout to 5s.

## Out of scope

- `Palace/Integration/*` (none in production), `Palace/AppInfrastructure/*`, `Palace/BookRegistry/*`, `Palace/Reader2/*` — production code is **read-only**.
- TPPBookRegistry architecture changes.
- AppContainer composition changes.
- Reader2 nav/readstate work (active on swarm_f3b9b087 branches).

## Verification before reporting done

1. Linter for each scoped file returns 0 blocking violations (or only FLAKE-003-OK allow-listed sites).
2. Each test class still passes (large-corpus tests may take 60+ seconds — that's expected).
3. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-f-integration-reader2-bookregistry.md` — list every FLAKE-003-OK addition with the documented reason. The integrator will sanity-check.

Do NOT commit. Do NOT push.
