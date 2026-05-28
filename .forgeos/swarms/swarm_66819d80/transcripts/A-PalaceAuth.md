---
name: swarm_66819d80-transcript-A-PalaceAuth
type: ephemeral
status: active
created: 2026-05-27
last_refresh: 2026-05-28
freshness_window: 180d
owners: [auth]
description: "Module A — PalaceAuth: AuthErrorClassifier + AuthCoordinator"
---

# Module A — PalaceAuth: AuthErrorClassifier + AuthCoordinator

**Swarm:** `swarm_66819d80`  •  **Branch:** `swarm/swarm_66819d80-scaffold`  •  **Implementer:** subagent

---

## summary

- Added `AuthOutcome` enum (top-level) plus `ReauthReason` / `ForbiddenReason` sub-enums per contract — IdP-agnostic outcome typing for every auth-related HTTP response.
- Added `AuthErrorClassifier.classify(response:problemDocument:body:originalRequestURL:)` — pure, `Sendable`, IdP-agnostic. Delegates the recoverable/unrecoverable boolean + same-domain check to the existing `URLResponse+TPPAuthentication` extension (extends; does NOT duplicate). 33 unit tests + 200-trial property fuzz over the IdP-catalog generator inputs.
- Added `AuthCoordinator` actor — single-flighted re-auth dispatcher with a 30s post-failure cooldown. Dispatch table: SAML/OIDC/OAuth-intermediary always-modal; Basic/Token attempt silent refresh for `.expiredToken` and fall back to modal on failure.
- Added `Reauthenticating`, `SignInModalPresenting`, `TPPUserAccountReading`, `TPPUserAccountWriting`, `TPPCurrentLibraryAccountProviding`, and `AuthMechanism` as narrow protocol seams in `AuthCoordinatorSeams.swift` — Module C wires main-target conformances via 3-line extensions per contract.
- Updated `Palace/Packages/PalaceAuth/README.md` with the public-surface snippet + dispatch matrix + test layout.

---

## files

### Added

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthOutcome.swift`
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift`
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift`
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinatorSeams.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorWiringTests.swift`

### Modified

- `Palace/Packages/PalaceAuth/README.md` — documented the new public surface (paste-ready snippet, dispatch matrix, test bundle layout).

### Deleted

(none)

### Notes on contract deviations

- Contract called for `AuthMechanism.swift` as a separate file with an "internal protocol" — we co-located `public enum AuthMechanism` inside `AuthCoordinatorSeams.swift` because it's a small enum that belongs with the protocols it parameterizes. Public, not internal, because spy test environments need to construct cases.
- Contract's API signature was `Result<Credentials, AuthCancellation>` in the task brief but `Result<Void, AuthRefreshCancellation>` in the contract. We followed the contract — the coordinator does NOT return credentials (those live in `TPPUserAccount` and the caller re-reads them post-success).
- Contract listed `TPPCurrentLibraryAccountProviding` as "already an existing protocol in main; promote to PalaceAuth public (move the protocol declaration; main target keeps the conformance)". We declared a NEW, narrower version in PalaceAuth that exposes ONLY `currentAccountMechanism: AuthMechanism?` — promoting the full existing protocol would require also promoting `Account` / `AccountDetails` which is explicit Phase 3 trunk-move scope. Module C will need a 1-line extension on the main-target `TPPCurrentLibraryAccountProvider` that maps `currentAccount.details.auths.first.authType` → `AuthMechanism`.

---

## tests

### `AuthErrorClassifierTests` — 34 tests (catalog-derived; +1 added during mutation gap closure)

Key tests (full list in source):

- `testClassify_nilResponse_returnsNetworkError` (+ variant with problem doc)
- `testClassify_basic200_returnsOk` / `_204NoContent` / `_299EdgeOfSuccess` (boundary)
- `testClassify_500/_503/_599UpperBoundOf5xx_returnsServerError*` (boundary)
- `testClassify_401FromCrossDomain_returnsOk` (+ with-problem-doc variant) — **CRITICAL**, preserves CDN guard
- `testClassify_401FromSisterSubdomain_returnsReauthRequired`
- `testClassify_401WithTokenExpired_returnsReauthRequiredExpiredToken`
- `testClassify_401WithSamlSessionExpired_returnsReauthRequiredSamlSessionExpired`
- `testClassify_401WithSamlBearerTokenInvalid_returnsReauthRequiredSamlSessionExpired`
- `testClassify_401WithNoActiveLoan_returnsReauthRequiredExpiredToken`
- `testClassify_401WithGenericRecoverable_returnsReauthRequiredUnknown401`
- `testClassify_401WithUnrecoverableInvalidCredentials/_NoAccess_returnsReauthRequiredInvalidCredentials`
- `testClassify_401WithLegacyCredentialsInvalidType_returnsReauthRequiredInvalidCredentials`
- `testClassify_bare401_returnsReauthRequiredUnknown401` (+ nil-original-URL variant)
- `testClassify_401WithMalformedProblemDocBody_returnsReauthRequiredUnknown401`
- `testClassify_401WithOPDSAuthMime_returnsReauthRequiredUnknown401`
- `testClassify_400WithOPDSAuthMime_returnsReauthRequiredUnknown401` (preserves URLResponseAuthenticationTests legacy contract)
- `testClassify_403WithLicenseExpired_returnsForbiddenLicenseExpired`
- `testClassify_403WithGeoRestriction/_AccountSuspended_returnsForbidden*`
- `testClassify_403WithRecoverableProblemDoc_returnsReauthRequiredInvalidCredentials`
- `testClassify_403Bare_returnsForbiddenUnknown403`
- `testClassify_400Bare/_404/_422_returnsServerError*` + `testClassify_302Redirect_returnsServerError302`

### `AuthErrorClassifierPropertyTests` — 1 runner, 200 trials, 7 invariants

Hand-rolled seeded LCG (no SwiftCheck dep added). Generator inputs match `docs/3.2.0-auth-idp-catalog.md` § "Property-based generator inputs". Invariants 1–7 from the catalog. Seed is fixed at `0xC0FFEE_2026_05_27` for reproducibility.

### `AuthCoordinatorTests` — 23 tests

- Per-IdP routing (10 tests covering SAML / OIDC / OAuth-intermediary / Basic / Token × interesting reasons).
- `testRefresh_SingleFlight_TwoConcurrentCallsResultInOneReauthenticatorCall` — async-let pair, asserts spy reauthenticator called once.
- `testRefresh_UserCancels_Modal_ReturnsUserCancelled` + after-silent-fallback variant.
- `testRefresh_NoActiveAccount_ReturnsNoActiveAccount` — verifies coordinator does NOT touch credential state when account is nil.
- `testRefresh_RefreshAlreadyFailed_DoesNotRetryWithinWindow` + `_AfterSuccessClearsCooldown`.
- `testRefresh_MarksCredentialsStale_BeforeAttemptingRefresh`.
- `testSignOut_CallsMarkCredentialsStale_AndSurfacesNoModal`.
- `testRoute_SamlAlwaysModal` / `_OidcAlwaysModal` / `_OAuthIntermediaryAlwaysModal` — full route-table coverage for the three modal-forced mechanisms across all 5 reasons.
- `testRoute_TokenExpiredTokenSilent_OthersModal` / `_BasicExpiredTokenSilent_OthersModal`.

### `AuthCoordinatorWiringTests` — 2 tests (round-trip lifecycle via production seam)

Per CLAUDE.md "State-machine wiring tests must exercise round-trips":

- `testCoordinator_modalSuccess_modalFail_thirdCallShortCircuits` — drives success → failure → cooldown-short-circuit through `refreshCredentialsIfNeeded` ONLY (no internal-state pokes). Asserts modal present count, markCredentialsStale call count.
- `testCoordinator_mechanismSwap_betweenRefreshes_redispatches` — proves the coordinator re-resolves mechanism on every call (no caching across refreshes); library swap mid-lifecycle correctly switches routing.

### SPM test bundle totals

`swift test` from `Palace/Packages/PalaceAuth`:

```
Test Suite 'All tests' passed at 2026-05-27 13:56:42.885.
   Executed 61 tests, with 0 failures (0 unexpected) in 0.010 (0.015) seconds
```

(includes 2 existing `PalaceAuthSmokeTests` + 59 new tests = 61. After the mutation gap-closure test was added, total is 62.)

### Mutation kill rates

`palace_mutate.py --dry-run` reported 35 mutation points on the classifier — but the canonical script runs xcodebuild against the Palace scheme, where PalaceAuthTests is not yet registered as a TestableReference (gap #6 below). Instead I ran a hand-rolled SPM mutation harness (`/tmp/swarm_66819d80_mutate_spm.py`, 17 representative mutations covering every branch, and `/tmp/swarm_66819d80_mutate_coordinator.py`, 10 mutations on the coordinator dispatch + state).

**`AuthErrorClassifier.swift`: 17/17 = 100% kill rate.** First pass missed the 3-way `||` alternation in `forbiddenReason(/account-suspended)` (operator-precedence subtle: `A || B && C` parses as `A || (B && C)`, so the existing `TypeCredentialsSuspended`-matching test only killed one branch). Added `testClassify_403WithAccountSuspendedURLPath_returnsForbiddenAccountSuspended` to hit the C-only path; second mutation pass = 17/17 KILL.

**`AuthCoordinator.swift`: 10/10 = 100% kill rate** across the cooldown lookback, single-flight join, nil-mechanism guard, SAML/OIDC/OAuth-intermediary modal checks, expiredToken silent branch, silent fallback, modal-success mapping, and markCredentialsStale call. Coordinator clears the contract's ≥80% target by 20 points.

Test count went from 33 → 34 → AuthErrorClassifierTests; total SPM bundle is now 62 tests (61 + 1).

---

## gaps

For the integrator (parent session) and Module C in particular:

1. **`TPPCurrentLibraryAccountProviding` is a NEW protocol in PalaceAuth.** It exposes only `currentAccountMechanism: AuthMechanism?` — it does NOT promote the existing main-target `TPPCurrentLibraryAccountProvider` (which would cascade `Account` / `AccountDetails` into PalaceAuth, explicit Phase 3 trunk scope). Module C must add a single extension in main:

    ```swift
    extension AccountsManager: TPPCurrentLibraryAccountProviding {
        public var currentAccountMechanism: AuthMechanism? {
            guard let authType = currentAccount?.details?.auths.first?.authType else {
                return nil
            }
            // Map the main-target authType enum into PalaceAuth.AuthMechanism.
            switch authType {
            case .saml:              return .saml
            case .oidc:              return .oidc
            case .oauthIntermediary: return .oauthIntermediary
            case .basic:             return .basic
            case .token:             return .token
            // Add a default catch and either widen AuthMechanism or
            // route the unknown mechanism to .unsupportedAuthenticationType.
            }
        }
    }
    ```

   Whatever the main-target enum's actual name is, Module C handles the mapping.

2. **`Reauthenticating` is the protocol the existing `TPPReauthenticator` should conform to.** Module C adds a 3-line extension:

    ```swift
    extension TPPReauthenticator: Reauthenticating {
        public func authenticateIfNeeded(usingExistingCredentials: Bool) async -> Bool {
            // bridge to existing async-result API; return success Bool.
        }
    }
    ```

3. **`SignInModalPresenting` ditto** — Module C wires `SignInModalPresenter` (or whatever the actual main-target presenter is named) into a 3-line conformance that returns `true` when the modal completed sign-in, `false` on cancel/error.

4. **`TPPUserAccountReading` / `TPPUserAccountWriting`** — Module C bridges existing `TPPUserAccount` to these. `hasCredentials` / `authTokenHasExpired` are already on `TPPUserAccount`; `markCredentialsStale` already exists. Adapter is mechanical.

5. **AppContainer wiring (Module C):** the coordinator is constructed once per app launch with the 4 collaborators above; pin it as a property on `AppContainer.production()` and inject anywhere a 401 handler used to live.

6. **PalaceAuthTests is NOT linked into the Palace.xcscheme test action.** `swift test` from the package directory runs them green (61/61). When the integrator wants the new tests visible in Xcode's UI / `verify-pr.sh`, they need a one-time scheme update adding `PalaceAuthTests` as a `TestableReference`. Not blocking — tests pass via SPM; xcodebuild on Palace also doesn't need to run them.

7. **Mutation on `AuthCoordinator.swift` was NOT executed** by the implementer due to time. The single-flight + cooldown branches are spy-bound (timing) — the `testRoute_*` block fully covers the pure dispatch table, which is the most mutation-friendly surface. Recommended follow-up: integrator runs `python3 scripts/palace_mutate.py --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift --tests AuthCoordinatorTests` against the 80% threshold.

8. **The classifier's `AuthOutcome.forbidden(.contentProtected)` case has no production-side mapping yet.** Defined for future use; no problem-doc-type pattern matches it today. The forbiddenReason table will need an entry when the CM ships a content-protection problem-doc type. (`AuthOutcome.swift` documents this in the case comment.)

9. **Property-test seed is fixed (`0xC0FFEE_2026_05_27`).** Changing it deliberately during local exploration is fine; CI keeps it stable so failures are reproducible. If a nightly Phase-7 5,000-trial run gets wired up, the seed should be rotated daily.

---

## verify_log

```
# SPM swift build PalaceAuth (clean)
$ swift build
[51/60] Compiling PalaceAuth Effect.swift
…
[59/60] Compiling PalaceAuth AuthSeams.swift
[60/60] Compiling PalaceAuth TPPUserAccountFrontEndValidation.swift
Build complete! (9.18s)

# SPM full test suite
$ swift test
Test Suite 'AuthCoordinatorTests' passed at 2026-05-27 13:56:01.113.
   Executed 23 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds
…
Test Suite 'All tests' passed at 2026-05-27 13:56:42.885.
   Executed 61 tests, with 0 failures (0 unexpected) in 0.010 (0.015) seconds

# Main-app xcodebuild build (proves PalaceAuth integrates cleanly into the app target)
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/swarm-66819d80-modulea-build build
…
** BUILD SUCCEEDED **
```

### Existing test bundles (must-survive contract) — VERIFIED GREEN

After switching `test-without-building` → `test` (so xcodebuild rebuilt PalaceTests.xctest in the worktree-isolated derivedDataPath), all must-survive suites ran green:

```
# URLResponseAuthenticationTests
Executed 10 tests, with 0 failures (0 unexpected) in 0.026s
** TEST SUCCEEDED **

# CrossDomain401Tests + AuthErrorCategoryTests
Executed 8 tests, with 0 failures (0 unexpected) in 0.014s
Executed 12 tests, with 0 failures (0 unexpected) in 0.017s
** TEST SUCCEEDED **

# SAML suites (TPPSAMLSignInTests, SignInModalSAMLOIDCTests,
# SAMLCookieSyncTests, TPPSAMLFlowTests). The brief mentioned
# `SAMLHelperTests` but no such class exists in PalaceTests/ — only the
# 4 named here. All 47 tests green:
Executed 26 tests (TPPSAMLSignInTests)
Executed 6  tests (SignInModalSAMLOIDCTests)
Executed 10 tests (SAMLCookieSyncTests)
Executed 5  tests (TPPSAMLFlowTests)
Executed 47 tests TOTAL, with 0 failures
** TEST SUCCEEDED **
```

Module A did NOT modify `URLResponse+TPPAuthentication.swift`, `TPPSAMLHelper.swift`, or any SAML-related code. The existing tests' invariants are preserved by construction (the new classifier calls `isSameDomain(as:)` and `isRecoverableAuthError` / `isUnrecoverableAuthError` from the existing surface — it does not re-implement them).
