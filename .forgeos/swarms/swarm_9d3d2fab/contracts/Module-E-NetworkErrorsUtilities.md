# Module E — Network/Errors/Utilities (CI-flake migration)

## Files in scope (8)

| Path | FLAKE-001 | FLAKE-002 | FLAKE-003 |
|------|-----------|-----------|-----------|
| PalaceTests/Network/TPPNetworkExecutorTests.swift | — | L345, L387 | — |
| PalaceTests/Network/NetworkRetryTests.swift | L319 (Thread.sleep) | — | — |
| PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift | — | — | L334 (180s! likely FLAKE-002 in disguise) |
| PalaceTests/Network/CredentialGuardTests.swift | — | — | L472, L494, L532, L560 (15s) |
| PalaceTests/ErrorHandling/TPPAlertUtilsTests.swift | — | L349 | — |
| PalaceTests/ErrorHandling/TPPProblemDocumentCacheManagerTests.swift | — | — | L188, L216 (30s) |
| PalaceTests/Utilities/GeneralCacheTests.swift | — | L237, L255 | — |
| PalaceTests/Utilities/TPPBackgroundExecutorTests.swift | L49 (Thread.sleep) | L69, L86, L109 | — |

Authoritative: `python3 scripts/lint-test-quality.py --per-file --file <path>`.

## Migration patterns

Standard. Specific guidance:

- **NetworkRetryTests.swift L319 (Thread.sleep 50ms)**: this is inside the retry loop driver. The 50ms simulates real backoff timing. Replace with `XCTestExpectation` driven by the retry's completion callback, OR factor out a `Clock` protocol the test can advance synchronously (the latter is a bigger change — prefer the expectation approach to stay in scope).

- **TokenRefreshAndRetryQueueTests.swift L334 (180s)**: comment around L334 acknowledges this is "very long" — likely the prior author hit FLAKE-002 in the surrounding asyncAfter. Read the surrounding code (L320-L350). If the 180s is a wait-for-asyncAfter pattern, fix the asyncAfter and drop the timeout to 5s. If it's a real long-running queue drain, FLAKE-003-OK with a documented reason.

- **CredentialGuardTests.swift (4× 15s timeouts at L472-L560)**: these are SAML/OIDC credential-guard happy-path tests. The 15s budget was added because the credential-guard path has multiple state-machine hops + a stubbed network round-trip. Drop to 5s if the FLAKE-002 sites in the same file (search for asyncAfter+fulfill) are also fixed. If a single test legitimately needs 15s, FLAKE-003-OK.

- **TPPBackgroundExecutorTests.swift L49 (Thread.sleep workDuration)**: the test simulates "long-running work" to verify the executor doesn't drop it. Replace with `awaitCondition` polling `executor.activeCount` or similar.

- **TPPBackgroundExecutorTests.swift L69, L86, L109 (3× asyncAfter+fulfill)**: drainMainQueue if the executor uses .main; awaitCondition if it uses .global.

## Out of scope

- `Palace/Network/*`, `Palace/ErrorHandling/*`, `Palace/Utilities/*` — production code is **read-only**.
- TPPNetworkQueue retry policy changes.
- Clock/scheduler abstraction (the bigger refactor) — note as "gap" if it would be cleaner but stay in test-file scope.

## Verification before reporting done

1. Linter for each scoped file returns 0 blocking violations (or only FLAKE-003-OK allow-listed).
2. Each test class still passes.
3. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-e-network-errors-utilities.md` — and note any FLAKE-003-OK sites added with their documented reason.

Do NOT commit. Do NOT push.
