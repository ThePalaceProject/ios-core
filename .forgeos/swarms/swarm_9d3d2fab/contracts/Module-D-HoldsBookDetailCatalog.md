# Module D — Holds/BookDetail/Catalog (CI-flake migration)

## Files in scope (5)

| Path | FLAKE-001 | FLAKE-002 | FLAKE-003 |
|------|-----------|-----------|-----------|
| PalaceTests/Holds/HoldsViewModelTests.swift | — | L635, L661, L700 | — |
| PalaceTests/Book/BookDetailViewModelTests.swift | — | L1453 | — |
| PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift | — | — | L388, L398 (30s awaitCondition) |
| PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift | — | — | L115 (15s) |
| PalaceTests/Reader2/TPPReaderTOCBusinessLogicTests.swift | — | — | L77, L128, L144, L366 (10s — only blocks if linter still flags) |

Authoritative: `python3 scripts/lint-test-quality.py --per-file --file <path>`.

## Migration patterns

Standard patterns. Specific guidance:

- **HoldsViewModelTests.swift (L635, L661, L700)**: each is `DispatchQueue.main.asyncAfter(...) { exp.fulfill() }` followed by `wait(for: [exp], timeout: ...)`. The 3 sites are independent (different test methods). Each → `drainMainQueue()`.

- **BookDetailViewModelTests.swift L1453**: surrounding comments on L1022-1028 indicate the asyncAfter+wait is racing the registry pipeline. Use `awaitCondition` polling the registry's published state instead.

- **CatalogRepositoryStaleWhileRevalidateTests.swift (L388, L398)**: these are `await awaitCondition(timeout: 30.0) { ... }` — the helper itself is fine; the 30s timeout is the issue. The stale-while-revalidate path involves a UserDefaults check + a network round-trip; 5-10s is the right ceiling. Drop to 10s and add `// FLAKE-003-OK: SWR involves UserDefaults + stubbed-network; 10s budget covers cold-start contention.` if needed (but 5s is preferred — re-run the test class after to confirm).

- **OPDSFeedServiceStateMachineTests.swift L115**: 15s fulfillment timeout on a state-machine transition. The state machine should fire within 1s; drop to 5s.

- **Reader2/TPPReaderTOCBusinessLogicTests.swift (L77, L128, L144, L366)**: 10s `wait(for: [loaded], timeout: 10.0)` — linter floor is 15s, so these may NOT be flagged. Verify with `python3 scripts/lint-test-quality.py --per-file --file <path>` before touching. If they ARE flagged (some are 30s I missed), drop appropriately; if not, leave them alone.

## Out of scope

- `Palace/Holds/*`, `Palace/Book/*`, `Palace/CatalogDomain/*`, `Palace/OPDS2/*`, `Palace/Reader2/*` — production code is **read-only**.
- HoldsReducer / BorrowReducer logic.
- Catalog SWR architecture changes.

## Verification before reporting done

1. Linter for each scoped file returns 0 blocking violations.
2. Each test class still passes (typical `-only-testing:PalaceTests/<ClassName>`).
3. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-d-holds-bookdetail-catalog.md`.

Do NOT commit. Do NOT push.
