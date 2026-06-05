---
name: auth-verification-checklist
type: evolving
status: active
created: 2026-05-27
last_refresh: 2026-05-27
freshness_window: 180d
owners: [auth]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
---

<!-- audit-verified: PR #1018 and swarm_66819d80 are real; I orchestrated this swarm today (2026-05-27 → 2026-05-28) and the artifacts referenced exist at .forgeos/swarms/swarm_66819d80/. Migration status per Section 1 was verified by grep/file-read during the swarm's Phase 4/4.5/5. -->

# Auth area — verification checklist

**Owner area:** `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `Palace/Accounts/`, and the auth-error decision points in `Palace/Network/TPPNetworkResponder.swift`, `Palace/MyBooks/TokenRefreshInterceptor.swift`, `Palace/MyBooks/DownloadAuthRetryHandler.swift`, `Palace/MyBooks/BorrowOperation.swift`, `Palace/MyBooks/BookReturnService.swift`, `Palace/Audiobooks/AudiobookSessionManager.swift`.

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN. Without it, every new initiative re-discovers the same surface (PR #1018's architect produced ~1,000 lines of recon docs that should have started from a baseline like this).

**Last refresh:** 2026-05-28 (post PR #1018 — see `derived-improvements.md` entry for source).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites that handle 401/403, mutate TPPUserAccount, or read AccountDetails)

| File | Lines | What it does | Migration status |
|------|-------|-------------|------------------|
| `Palace/Network/TPPNetworkResponder.swift` | 221, 230, 367, 463 | Direct `statusCode == 401` checks | **MIGRATED** in PR #1018 — routes through `AuthErrorClassifier`. Cross-domain 401 carve-out + per-task `tokenRefreshAttempts < 2` budget intentionally retained. |
| `Palace/MyBooks/TokenRefreshInterceptor.swift` | 79, 116, 296 | Per-book auth-failure routing | **MIGRATED** in PR #1018 — routes through coordinator. OIDC silent-reauth at `triggerOIDCReauth` (line 533) preserved per Option A (silent on success, coordinator on failure). |
| `Palace/MyBooks/DownloadAuthRetryHandler.swift` | 95, 131 | Browser-session-expired + no-active-loan retry | **MIGRATED** in PR #1018. |
| `Palace/MyBooks/BorrowOperation.swift` | 540-576, 609-636, 643, 818, 821, 785 | Borrow-flow auth-error handling | **MIGRATED** in PR #1018. Per-book `hasBorrowReauthBeenAttempted` circuit breaker preserved. OIDC `attemptOIDCSilentReauth` body preserved per contract. |
| `Palace/MyBooks/BookReturnService.swift` | 302 | Return-flow auth-error handling | **MIGRATED** in PR #1018. Legacy `else` fallback retained for tests that don't inject a coordinator (will delete when fallback removed — tech debt). |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | 1125-1147 | Playback `.playbackFailed` re-auth | **MIGRATED** in PR #1018 — `shouldTriggerSAMLReauthForPlaybackFailure` boundary predicate preserved. |
| `Palace/SignInLogic/TPPSignInBusinessLogic.swift` | 376, 652, 666, 748 | Auth flow dispatch (basic/oauth/saml/oidc/token) | Sites 376/652/748 marked **OFF-LIMITS** by architect — they're sign-in-pipeline-internal, not consumer-side. Site 666 uses `isBrowserBased` post-PR #1018. |
| `Palace/Accounts/Library/Account.swift` | 246 | `isBrowserBased` definition | **LANDED** in PR #1018. `isOauth || isSaml || isOidc`. |
| `Palace/Settings/AccountDetailViewModel.swift` | 367, 759 | Auth-type-driven UI gating | Site 367 OFF-LIMITS (architect). Site 759 uses `isBrowserBased`. |
| `Palace/Settings/AccountDetailView.swift` | 85 | Sign-in prompt visibility | Uses `isBrowserBased`. |

**STILL UNMIGRATED** (next sprint candidates per PR #1018 deferral):
- `TokenRefreshInterceptor.swift:106` — still calls `indicatesAuthenticationNeedsRefresh`. Out-of-scope for PR #1018 TPPNetworkResponder-focused work.
- `DownloadAuthRetryHandler.swift:109` — same.

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Packages/PalaceAuth/` | SPM trunk | `AuthErrorClassifier`, `AuthCoordinator`, `AuthOutcome` enum, `AuthCoordinatorSeams` protocols, `AuthDecisionPayload`, `TPPSAMLHelper`, `AuthReducer`, `TokenRequest`, `TPPUserAccountFrontEndValidation` |
| `Palace/SignInLogic/` | Main target — auth flow UI + business logic | `TPPSignInBusinessLogic` + 7 extensions, `TPPReauthenticator`, `SignInModalView` + sheets, `LegacySAMLAuthAdapter`. **Next-sprint trunk move target** — currently in main, planned to move under PalaceAuth (see `~/.claude/plans/palace-3.2.0-auth-architecture.md`). |
| `Palace/Accounts/` | Main target | `Account`, `AccountDetails`, `AccountsManager`, `TPPUserAccount`, the 4 conformance adapters (`CoordinatorUserAccountAdapter`, `CoordinatorSignInModalPresenter`, `CoordinatorAccountProvider`, `TPPReauthenticator+Reauthenticating`) |
| `Palace/Network/` | Main target | `TPPNetworkResponder` (routes errors), `TPPNetworkExecutor` (sends requests), `URLResponse+TPPAuthentication` extension |

---

## 3. AuthCoordinator dispatch matrix (verify before changing routing logic)

| AuthMechanism | `.expiredToken` reason | `.invalidCredentials` | `.forbidden(...)` | `.serverError` | `.networkError` |
|---|---|---|---|---|---|
| `.basic` | silent refresh → modal fallback | modal | propagate to caller | propagate | propagate |
| `.token` | silent refresh → modal fallback | modal | propagate | propagate | propagate |
| `.saml` | always modal | always modal | propagate | propagate | propagate |
| `.oidc` | always modal (silent reauth is at TokenRefreshInterceptor's `triggerOIDCReauth`, NOT in coordinator) | always modal | propagate | propagate | propagate |
| `.oauthIntermediary` (Clever) | always modal | always modal | propagate | propagate | propagate |
| `.noActiveAccount` | `.noActiveAccount` outcome immediately | `.noActiveAccount` | `.noActiveAccount` | `.noActiveAccount` | `.noActiveAccount` |

Single-flight semantics: only one `refreshCredentialsIfNeeded(...)` in-flight at a time per coordinator instance. 30s post-failure cooldown — second calls within 30s of a failure short-circuit to `.refreshAlreadyFailed` without re-prompting.

---

## 4. IdP × scenario truth table (subset — full version at `docs/3.2.0-auth-idp-catalog.md`)

| IdP | Success | Expired token | Invalid creds | Server 5xx | Network fail | Malformed problem doc |
|-----|---------|--------------|--------------|-----------|-------------|---------------------|
| Basic | 200, no problem doc | 401 + problem doc `expired_token` | 401 + problem doc `invalid_credentials` | 5xx | nil response | 401 + non-JSON body |
| OAuth-intermediary (Clever) | 200 via redirect | 401 + redirect to IdP | 401 + cleared cookies | 5xx | nil | 401 + HTML body |
| OIDC | 200 + ID token | 401 + `expired_token`; silent reauth via ASWebAuthenticationSession at TokenRefreshInterceptor | 401 + IdP rejection | 5xx | nil | 401 + IdP-specific JSON |
| SAML (no SLO) | 200 + SAML assertion cookie | 401 + cookie expired (server-side) | 401 + IdP-specific redirect | 5xx | nil | varies by IdP |
| SAML (w/ SLO) | 200 + assertion cookie + SLO endpoint | Same as no-SLO | Same | Same | Same | Same |
| Library-specific Shibboleth (Cornell/RAILS/Sonoma/NJStateLib) | varies — see `docs/3.2.0-auth-idp-catalog.md` for per-IdP recordings | UNKNOWN for some — pending simdrive recordings | UNKNOWN for some | UNKNOWN for some | UNKNOWN for some | UNKNOWN for some |

11 IdP × scenario cells are still UNKNOWN — see `transcripts/D-fixtures-gap-report.md` for the recording plan.

---

## 5. Telemetry surface points (every auth decision emits)

| Surface point | File | Event | Payload extras |
|---------------|------|-------|----------------|
| `classifier.classify(...)` | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` | `classifierOutcome` | `(idp_type, library_uuid, status_code, problem_doc_type, decision)` |
| Coordinator refresh start | `AuthCoordinator.swift` | `refreshStart` | `+ reason` |
| Coordinator refresh end | `AuthCoordinator.swift` | `refreshEnd` | `+ outcome (.success / .userCancelled / .refreshAlreadyFailed)` |
| Modal cancel | `AuthCoordinator.swift` | `modalCancel` | `+ duration_ms` |
| Silent refresh outcome | `AuthCoordinator.swift` | `silentRefreshOutcome` | `+ outcome` |
| Cookie validation failure | (next sprint — when SAML internals move into PalaceAuth) | `cookieValidationFailed` | `+ cookie_count, expired_count` |
| Token refresh success/fail | `TokenRefreshInterceptor.swift` (delegate-style emission via main-target wrapper) | `tokenRefreshOutcome` | `+ http_status, error_code` |

Main-target wrapper: `AuthDecisionRecorder` in `Palace/AppInfrastructure/Telemetry/AuthDecisionRecorder.swift` — the only file that links FirebaseCrashlytics. PalaceAuth itself does NOT link Firebase; it emits via the `AuthDecisionRecording` protocol.

---

## 6. Test surface

**Existing test files** (385+ tests total per PR #1018 architect Phase 0):
- `PalaceTests/SignInLogic/SAMLHelperTests.swift` (5 tests)
- `PalaceTests/SignInLogic/TPPSAMLSignInTests.swift` (27)
- `PalaceTests/SignInLogic/SignInModalSAMLOIDCTests.swift` (8)
- `PalaceTests/SignInLogic/TPPSAMLFlowTests.swift` (new in PR #1018)
- `PalaceTests/SignInLogic/TPPBasicAuthTests.swift`
- `PalaceTests/Network/SAMLCookieSyncTests.swift` (8)
- `PalaceTests/Network/URLResponseAuthenticationTests.swift`
- `PalaceTests/Network/CrossDomain401Tests.swift`
- `PalaceTests/Network/AuthErrorCategoryTests.swift`
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (canonical round-trip reference)
- `PalaceTests/Accounts/AccountDetailsAuthenticationIsBrowserBasedTests.swift` (new in PR #1018)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift` (34)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift` (1 fuzz, 200 trials)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorTests.swift` (23)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorWiringTests.swift` (2)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthDecisionPayloadTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthTelemetryEmissionTests.swift`
- `PalaceTests/AppInfrastructure/AppContainerAuthCoordinatorWiringTests.swift` (renamed to *RegistrationTests* in PR #1018 reviewer fixup — file name still wiring per follow-up)
- `PalaceTests/AppInfrastructure/AuthCoordinatorTelemetryTests.swift`
- `PalaceTests/AppInfrastructure/AuthDecisionEventEmissionTests.swift`
- `PalaceTests/MyBooks/BookReturnServiceAuthCoordinatorTests.swift`
- `PalaceTests/MyBooks/BorrowOperationAuthCoordinatorTests.swift`
- `PalaceTests/MyBooks/TokenRefreshInterceptorAuthCoordinatorTests.swift`
- `PalaceTests/MyBooks/DownloadAuthRetryHandlerAuthCoordinatorTests.swift`
- `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift`

**Tests that test BEHAVIOR (must-survive any refactor):**
- Sign-in flow end-to-end (basic/saml/oidc/oauth/token)
- Sign-out behavior incl. credential clear
- 401 → coordinator → modal/refresh dispatch
- Multi-account credential isolation
- Round-trip state-machine wiring (`AccountsManagerStateMachineWiringTests`)

**Tests that test IMPLEMENTATION (can be rewritten when underlying changes):**
- Tests asserting on specific call orders inside `TPPSignInBusinessLogic`
- Tests that exercise the legacy `markCredentialsStale` direct-call path (only relevant until the legacy `else` fallback in BookReturnService is removed)

---

## 7. Known traps / anti-patterns (lessons from prior work)

- **Foreign-library cross-host 401** (added 2026-06-05 per wall-failure `2026-06-05-pr1018-icarus-cross-host-logout.md`): a 401 from a host that shares base-domain with the current account but does NOT belong to the current account's auth surface (different library backend within `*.palaceproject.io`, e.g. `gorgon.staging.palaceproject.io` vs `minotaur.dev.palaceproject.io`) must NOT be classified as `.reauthRequired`. The base-domain `isSameDomain` helper does NOT catch this. The fix is `Account.authSurfaceHosts` → `AuthErrorClassifier.currentAccountHostsProvider` → Rule 4b (foreign-host 401 → `.ok`). Tests live in `PalaceAuthTests/AuthErrorClassifierTests` (host-scoping tests) and `PalaceTests/Accounts/AccountAuthSurfaceHostsTests`. Property-fuzz Invariant 8 enforces this structurally. Sibling sites `TokenRefreshInterceptor:106` and `DownloadAuthRetryHandler:212` carry inline foreign-host guards with the same closure shape.
- **Two-surface auth model** (memory `saml_two_surface_auth_model.md`): bearer token + IdP cookie expire independently. Do NOT mark stale on `/patrons/me` 401 alone — the bearer might be valid but the cookie expired, or vice versa.
- **OIDC silent reauth uses ASWebAuthenticationSession directly** — not through AuthCoordinator. Don't accidentally route it through the coordinator (would break the silent UX).
- **Per-book circuit breaker** at BorrowOperation (`hasBorrowReauthBeenAttempted`) — process-wide coordinator single-flight is NOT a substitute. Both layers serve different roles.
- **Per-task token-refresh budget** at TPPNetworkResponder (`tokenRefreshAttempts < 2`) — preserved through PR #1018 migration. Cross-domain 401 carve-out at line 463 also preserved.
- **SAML cookie sync** between WKWebView and URLSession is fragile — see `feedback_saml_cookie_sync_workaround.md` (if exists in memory). Don't change cookie handling without device-testing each IdP.
- **`.accountNotFound` enum case** (memory `enum_conflation_account_not_found`) — currently overloaded with two meanings (real failure vs eviction marker). Next sprint candidate for split. Tests need explicit semantics pins per CLAUDE.md round-trip rules.

---

## 8. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1-3** — confirm the call-site map, module ownership, and dispatch matrix are still accurate. Add new sites or mark removed ones.
2. **Re-run the IdP catalog truth-table grep** — `python3 scripts/find-auth-call-sites.py` (if exists) or manual.
3. **Re-run test inventory** — `find PalaceTests -name "*Auth*Tests.swift" -o -name "*SignIn*Tests.swift" -o -name "*SAML*Tests.swift" | wc -l` — confirm count and update Section 6.
4. **Re-grep scattered predicates** — `grep -rn "isOauth.*isSaml\|isSaml.*isOauth\|isOauth.*isOidc" Palace/` — any new matches outside Section 1's known sites need triage.
5. **Re-check critical-path tests pass** — run the must-survive-behavior tests from Section 6 against current `develop` BEFORE the swarm starts, so post-swarm regressions are attributable.
6. **Update Section 9 (refresh history)** with date + your initials.

---

## 9. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | swarm_66819d80 architect (via this PR) | Initial baseline derived from PR #1018 Phase 0 recon docs. Lifted from `docs/3.2.0-auth-recon.md` + `-deps.md` + `-test-inventory.md` + `-idp-catalog.md`. |

---

**This file is owned by the auth area.** If you change anything in the modules listed in Section 2, update the relevant section here before you commit. The Definition of Done (CLAUDE.md) treats out-of-date area checklists as scope debt.
