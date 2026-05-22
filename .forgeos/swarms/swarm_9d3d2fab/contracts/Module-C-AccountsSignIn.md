# Module C — Accounts/SignIn (CI-flake migration)

## Files in scope (8)

| Path | FLAKE-001 | FLAKE-002 | FLAKE-003 |
|------|-----------|-----------|-----------|
| PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift | L334, L747 (Thread.sleep) | L118, L267, L367, L423, L495, L603 (6 asyncAfter+fulfill) | — |
| PalaceTests/Accounts/TPPCredentialIsolationE2ETests.swift | — | — | L160 (30s) |
| PalaceTests/Accounts/UserAccountPublisherTests.swift | — | — | L102 (15s) |
| PalaceTests/SignInLogic/TPPSignInBusinessLogicOAuthTests.swift | — | L567 | — |
| PalaceTests/SignInLogic/TPPSignInBusinessLogicSignOutTests.swift | — | L308 | — |
| PalaceTests/SignInLogic/LegacySAMLProblemDocumentPropagationTests.swift | — | L303 | — |
| PalaceTests/SignInLogic/TPPAgeCheckDeepTests.swift | — | — | L161 (30s) |
| PalaceTests/SignInLogic/SignInWebSheetIntegrationTests.swift | — | — | L106 (30s) |

Authoritative list per file: `python3 scripts/lint-test-quality.py --per-file --file <path>`.

## Migration patterns

Standard patterns from plan.md. Two sites need extra care:

- **AccountsManagerStateMachineWiringTests.swift Thread.sleep (L334, L747)**: these are inside `mockResponder.respondWithDelay` blocks. The 50ms sleep simulates real network latency. Replace with an `XCTestExpectation` driven by the responder's completion handler, NOT with `drainMainQueue` — the state machine drives its own timing here.

- **SignInWebSheetIntegrationTests.swift L106 (30s timeout)**: this is the OAuth/SAML web sheet round-trip test. If the test genuinely exercises an OAuth flow with real timing (e.g. interacting with a stubbed identity provider that has built-in delays), `// FLAKE-003-OK: <reason>` is the right call. If the 30s is just a timeout-as-padding around an asyncAfter, fix the asyncAfter.

## Out of scope

- `Palace/Accounts/*`, `Palace/SignInLogic/*` — production code is **read-only**.
- The SAML refactor on `refactor/saml-auth-architecture` branch — that's a separate sprint.
- AccountStateStore / TPPUserAccount singleton elimination (Phase 2).
- Adding new tests.

## Verification before reporting done

1. Linter for each scoped file returns 0 blocking violations.
2. Each migrated test class still passes:
   ```bash
   xcodebuild test -project Palace.xcodeproj -scheme Palace \
     -destination "id=$HARNESS_SESSION_SIM_UDID" \
     -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests \
     -only-testing:PalaceTests/TPPCredentialIsolationE2ETests \
     -only-testing:PalaceTests/UserAccountPublisherTests \
     -only-testing:PalaceTests/TPPSignInBusinessLogicOAuthTests \
     -only-testing:PalaceTests/TPPSignInBusinessLogicSignOutTests \
     -only-testing:PalaceTests/LegacySAMLProblemDocumentPropagationTests \
     -only-testing:PalaceTests/TPPAgeCheckDeepTests \
     -only-testing:PalaceTests/SignInWebSheetIntegrationTests
   ```
3. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-c-accounts-signin.md`.

Do NOT commit. Do NOT push.
