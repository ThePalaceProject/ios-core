---
name: swarm_66819d80-contract-A-PalaceAuth
type: immutable
status: active
created: 2026-05-27
last_refresh: 2026-05-28
freshness_window: never
owners: [auth]
description: "Module A — PalaceAuth: `AuthErrorClassifier` + `AuthCoordinator`"
---

# Module A — PalaceAuth: `AuthErrorClassifier` + `AuthCoordinator`

**Swarm:** `swarm_66819d80`  •  **Base SHA:** `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Depends on:** none (Day 1 parallel with Module B)

---

## Goal

Introduce two new public types in the `PalaceAuth` SPM package that
become the **only** seams every network consumer + every re-auth
caller will hit in 3.2.0:

1. **`AuthErrorClassifier`** — pure function: given an HTTP response
   tuple, returns a discrete `AuthOutcome` (input-driven, IdP-agnostic).
2. **`AuthCoordinator`** — actor: the only public re-auth entrypoint.
   Internally dispatches to SAML / OAuth / OIDC / Basic / Clever / Token
   mechanisms; callers don't know.

Module C (Day 2) wires existing callers through this surface. Module D
(Day 2) instruments it for telemetry. Module B is independent.

---

## In-scope files

### Add (new)

```
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthOutcome.swift
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthMechanism.swift            (internal protocol)
Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinatorSeams.swift     (Reauthenticator + SignInModalPresenting protocols)
Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift
Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift
Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorTests.swift
```

### Modify (existing, extend in-place — do NOT duplicate)

```
Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift
Palace/Packages/PalaceAuth/README.md  (document new public surface)
```

`URLResponse+TPPAuthentication.swift` is the existing classifier (under
another name). Module A MUST extend it — not duplicate it. The
`AuthErrorClassifier.classify(...)` implementation delegates to the
existing `indicatesAuthenticationNeedsRefresh(with:originalRequestURL:)`
extension to produce the boolean, then **augments** with problem-doc
type → `ReauthReason` mapping and `.forbidden` / `.serverError` /
`.networkError` discrimination that the existing extension doesn't make.

### OFF-LIMITS

- Anything outside `Palace/Packages/PalaceAuth/`. Module A does NOT
  modify any caller (that's Module C).
- `TPPSAMLHelper`, `AuthReducer`, `TPPUserAccountFrontEndValidation`,
  `TokenRequest` — already in PalaceAuth, do not refactor.
- `AuthSeams.swift` — Module A may EXTEND with `Reauthenticating` /
  `SignInModalPresenting` protocols, but do NOT change the existing
  `TPPLibraryAccountReadable` / `TPPAuthenticationDocumentReadable` /
  `PushTokenDeleting` declarations.

---

## API contract

### `AuthOutcome.swift`

```swift
public enum AuthOutcome: Equatable, Sendable {
    case ok
    case reauthRequired(reason: ReauthReason)
    case forbidden(reason: ForbiddenReason)
    case serverError(status: Int)
    case networkError
}

public enum ReauthReason: Equatable, Sendable {
    case expiredToken
    case invalidCredentials
    case samlSessionExpired
    case oidcRefreshFailed
    case unknown401
}

public enum ForbiddenReason: Equatable, Sendable {
    case licenseExpired
    case geoRestriction
    case accountSuspended
    case contentProtected
    case unknown403
}
```

### `AuthErrorClassifier.swift`

```swift
public struct AuthErrorClassifier: Sendable {
    public init()

    /// Pure function: given a response tuple, return the discrete outcome.
    /// Knows nothing about the active IdP. Coordinator dispatches on the
    /// outcome.
    ///
    /// - Parameters:
    ///   - response: the HTTPURLResponse (nil for transport failures)
    ///   - problemDocument: parsed problem doc if MIME matched
    ///   - body: raw body bytes (consulted only for malformed-doc detection)
    ///   - originalRequestURL: pre-redirect URL (for cross-domain guard)
    public func classify(
        response: HTTPURLResponse?,
        problemDocument: TPPProblemDocument?,
        body: Data?,
        originalRequestURL: URL?
    ) -> AuthOutcome
}
```

Implementation outline (TDD-driven from `docs/3.2.0-auth-idp-catalog.md`):

```
1. response == nil                          → .networkError
2. statusCode ∈ 200...299                   → .ok
3. statusCode ∈ 500...599                   → .serverError(status:)
4. statusCode == 401 with cross-domain mismatch (use the existing
   isSameDomain helper)                     → .ok
5. statusCode == 401 + recoverable problem doc:
     type matches token-expired             → .reauthRequired(.expiredToken)
     type matches saml-bearer-token-invalid
       or saml-session-expired              → .reauthRequired(.samlSessionExpired)
     type matches TypeNoActiveLoan          → .reauthRequired(.expiredToken)  (coordinator re-dispatches per IdP)
     other recoverable                      → .reauthRequired(.unknown401)
6. statusCode == 401 + unrecoverable problem doc:
                                            → .reauthRequired(.invalidCredentials)
7. statusCode == 401 + legacy credentials-invalid type:
                                            → .reauthRequired(.invalidCredentials)
8. statusCode == 401 bare (no problem doc)  → .reauthRequired(.unknown401)
9. statusCode == 401 + malformed body       → .reauthRequired(.unknown401)
10. statusCode == 403 + license-expired type → .forbidden(.licenseExpired)
11. statusCode == 403 + other recoverable forbidden → .reauthRequired(.invalidCredentials)
12. statusCode == 403 bare                   → .forbidden(.unknown403)
13. other 4xx                                → .serverError(status:)
```

Rules 5/6/7/8 already exist as a boolean in
`URLResponse+TPPAuthentication.swift`. Module A's job is to translate
the boolean into the typed outcome and add the discrimination at rules
1/3/10/11/12. **Do not re-implement the cross-domain logic** — call into
the existing helper.

### `AuthCoordinator.swift`

```swift
public actor AuthCoordinator {
    public init(
        reauthenticator: Reauthenticating,
        modalPresenter: SignInModalPresenting,
        userAccountProvider: TPPUserAccountWriting & TPPUserAccountReading,
        accountProvider: TPPCurrentLibraryAccountProviding
    )

    /// Idempotent: the same call site can invoke this on every 401;
    /// the coordinator single-flights and returns the result of the
    /// in-flight refresh (or initiates one).
    public func refreshCredentialsIfNeeded(
        reason: ReauthReason
    ) async -> Result<Void, AuthRefreshCancellation>

    /// Force a sign-out + clear (used by ForceReset; out of normal scope).
    public func signOut() async
}

public enum AuthRefreshCancellation: Error, Equatable {
    case userCancelled
    case noActiveAccount
    case refreshAlreadyFailed
    case unsupportedAuthenticationType
}
```

The coordinator inspects
`accountProvider.currentAccount.details?.auths` to determine which
mechanism to dispatch to. Internally:

- `.expiredToken` for OAuth/Token → `Reauthenticating.authenticateIfNeeded(usingExistingCredentials: true)` (silent refresh)
- `.samlSessionExpired` or any reason for SAML → `SignInModalPresenting.presentSignInModalForCurrentAccount(...)`
- `.oidcRefreshFailed` for OIDC → modal (OIDC has no client-side refresh)
- `.invalidCredentials` → modal regardless of type
- `.unknown401` → modal regardless of type (safe default)

`Reauthenticating` and `SignInModalPresenting` are new protocols
declared in `AuthCoordinatorSeams.swift`. Production conformances:

- `TPPReauthenticator` (existing in main) conforms to `Reauthenticating`
  via a 3-line extension in main (Module C wires).
- `SignInModalPresenter` (existing in main) conforms to
  `SignInModalPresenting` via a 3-line extension in main (Module C
  wires).

Module A SHIPS the protocols + a coordinator implementation that takes
them as constructor parameters. It does NOT wire main-target
conformances — those go in Module C's PR.

### `TPPUserAccountWriting` / `TPPUserAccountReading`

Module A declares **only what the coordinator actually needs**:

```swift
public protocol TPPUserAccountReading: AnyObject {
    var hasCredentials: Bool { get }
    var authTokenHasExpired: Bool { get }
    var authState: TPPAccountAuthState { get }   // enum already exists in main
}

public protocol TPPUserAccountWriting: AnyObject {
    func markCredentialsStale()
}
```

This is intentionally narrow. The full ~17-setter split is a Phase 3
trunk-move scope per `docs/3.2.0-auth-deps.md` and NOT in this swarm.

`TPPCurrentLibraryAccountProviding` is already an existing protocol in
main; promote to PalaceAuth public (move the protocol declaration; main
target keeps the conformance).

---

## Test contract

### `AuthErrorClassifierTests.swift` — ~30 unit tests

One test per grounded row in `docs/3.2.0-auth-idp-catalog.md`. Tests
construct `HTTPURLResponse` + `TPPProblemDocument` + URL fixtures, call
`classify(...)`, and `XCTAssertEqual` the result.

Required tests (non-exhaustive, see catalog for full list):

- `testClassify_basic200_returnsOk`
- `testClassify_bare401_returnsReauthRequiredUnknown401`
- `testClassify_401WithCredentialsInvalidProblemDoc_returnsReauthRequiredInvalidCredentials`
- `testClassify_401WithTokenExpired_returnsReauthRequiredExpiredToken`
- `testClassify_401WithSamlSessionExpired_returnsReauthRequiredSamlSessionExpired`
- `testClassify_401WithSamlBearerTokenInvalid_returnsReauthRequiredSamlSessionExpired`
- `testClassify_401WithNoActiveLoan_returnsReauthRequiredExpiredToken`
- `testClassify_401WithUnrecoverableNoAccess_returnsReauthRequiredInvalidCredentials`
- `testClassify_401FromCrossDomain_returnsOk` ← **critical — preserves 401 CDN guard**
- `testClassify_403WithLicenseExpired_returnsForbiddenLicenseExpired`
- `testClassify_403Bare_returnsForbiddenUnknown403`
- `testClassify_500_returnsServerError500`
- `testClassify_503_returnsServerError503`
- `testClassify_nilResponse_returnsNetworkError`
- `testClassify_401WithMalformedProblemDocBody_returnsReauthRequiredUnknown401`
- `testClassify_401WithOPDSAuthMime_returnsReauthRequiredUnknown401`

### `AuthErrorClassifierPropertyTests.swift` — 1 test runner, 200 trials per CI run

Generator over the 4 dimensions defined in
`docs/3.2.0-auth-idp-catalog.md` § "Property-based generator inputs".
Asserts the 7 invariants listed there. Use SwiftCheck **only if it's
already an SPM dep** — otherwise hand-roll a simple seeded RNG so we
don't add a dep.

**Mutation gate:** AuthErrorClassifier.swift MUST hit 100% mutation kill
rate via `scripts/palace_mutate.py`. Discrete pure function = no excuses.

### `AuthCoordinatorTests.swift` — ~18 unit tests

One test per (IdP type × ReauthReason) cell, using a spy
`Reauthenticating` and a spy `SignInModalPresenting`. Required:

- Per-IdP routing tests (5 IdPs × main reasons = ~10 tests)
- `testRefresh_SingleFlight_TwoConcurrentCallsResultInOneReauthenticatorCall`
- `testRefresh_UserCancels_Modal_ReturnsUserCancelled`
- `testRefresh_NoActiveAccount_ReturnsNoActiveAccount`
- `testRefresh_RefreshAlreadyFailed_DoesNotRetryWithinWindow`
- `testRefresh_UnsupportedAuthType_ReturnsUnsupportedAuthenticationType`
- `testRefresh_SamlReason_ForcesModalEvenIfReauthenticatorAvailable`
- `testRefresh_OidcReason_ForcesModalBecauseNoClientSideRefresh`
- `testSignOut_callsReauthenticatorSignOut_andClearsModalState`

### `AuthCoordinatorWiringTests.swift` — round-trip wiring (CLAUDE.md mandate)

Per CLAUDE.md "state-machine wiring tests must exercise round-trips":

- `testCoordinator_loggedIn_refresh_loggedOutByModal_refresh_loggedInAgain` — full lifecycle through the production seam, NOT direct setter shortcuts.

### Must NOT break

The 33 tests in `URLResponseAuthenticationTests.swift` MUST keep passing
unchanged. If any break, the classifier extension was rewritten instead
of extended — back out and re-implement on top of the existing
boolean.

---

## TDD assertion outline (Phase 1 protocol the implementer follows)

```
Day 1 AM:
  1. Read docs/3.2.0-auth-idp-catalog.md end-to-end.
  2. Write AuthOutcome.swift (just the enums; no logic). Compile.
  3. Write AuthErrorClassifierTests.swift with 1st test (basic 200 → .ok). Fails: type doesn't exist.
  4. Write minimal AuthErrorClassifier with hard-coded .ok. Test passes.
  5. Add 2nd test (bare 401 → .reauthRequired(.unknown401)). Fails.
  6. Implement statusCode dispatch. Test passes.
  7. Iterate: add a test, make it pass, refactor. ~30 cycles.
  8. Add property test runner once unit tests cover the major branches.
  9. Run mutation: `python3 scripts/palace_mutate.py --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift --tests AuthErrorClassifierTests`. Target 100% kill.

Day 1 PM:
  10. Write AuthCoordinatorSeams.swift (protocols only). Compile.
  11. Write AuthCoordinatorTests.swift with 1st test (OAuth + .expiredToken → reauthenticator.authenticateIfNeeded called once). Fails.
  12. Implement minimal AuthCoordinator. Test passes.
  13. Iterate through the 18 tests.
  14. Add the wiring round-trip test LAST.
  15. Re-run mutation across both files. Target 100% kill on classifier, 80%+ on coordinator (some routing branches are inherently hard to mutate-test against pure spies).
  16. Update PalaceAuth/README.md to document the new public surface.
```

---

## What NOT to do

1. **Do NOT duplicate the cross-domain logic.** The existing
   `URLResponse+TPPAuthentication.isSameDomain` helper is the source of
   truth. Call into it.
2. **Do NOT add new dependencies to PalaceAuth's Package.swift.**
   PalaceAuth currently depends on PalaceLogging + PalaceNetwork +
   PalaceCatalog. Don't add Crashlytics (Module D wires telemetry in
   main).
3. **Do NOT wire main-target callers.** That's Module C's PR. Module A
   may leave a TODO in `Palace/MyBooks/BorrowOperation.swift` (etc.) ONLY
   IF the comment is `// TODO(swarm_66819d80 Module C): migrate to
   AuthCoordinator` — never silently change caller code.
4. **Do NOT design a strategy pattern.** Coordinator's internal switch
   on `authenticationType` is the right level of indirection per the
   `calm-knitting-thunder.md` rejection note.
5. **Do NOT change `AuthReducer.AuthMethodType`** — that enum already
   exists with `.requiresBrowserRefresh`; if anything, the coordinator
   may CALL it. Don't replace it.
6. **Do NOT split TPPUserAccount fully.** Only the 4 read methods + 1
   write method the coordinator needs. The full split is Phase 3 trunk
   work.

---

## Pbxproj wiring

New Swift files under `Palace/Packages/PalaceAuth/Sources/PalaceAuth/`
and `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/` are picked up
automatically by SPM. **No `pbxproj_add_swift.rb` invocation required**
— PalaceAuth is an SPM package, not part of the xcodeproj's source
phase.

(If at any point the implementer needs a NEW file in
`Palace/SignInLogic/` or anywhere in the main target, THAT requires
`scripts/pbxproj_add_swift.rb` per CLAUDE.md.)

---

## Acceptance

- All 30 + 1 property + 18 + 1 wiring = **50 new tests** green.
- All 33 existing `URLResponseAuthenticationTests` green.
- `AuthErrorClassifier.swift` mutation kill rate: 100%.
- `AuthCoordinator.swift` mutation kill rate: ≥80% (some routing
  branches are inherently spy-bound).
- `PalaceAuth/README.md` documents the public surface (paste-ready
  snippet at the top of the file).
- No caller-site changes; no main-target source-file additions.
- `swift build` against PalaceAuth succeeds in isolation: `cd Palace/Packages/PalaceAuth && swift test`.
- Build the main app once after merge to confirm nothing breaks:
  `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`.

---

## Evidence to attach (for forge-review)

- `unit_test`: PalaceAuthTests output (count + green).
- `lint`: `swiftlint` on the new files.
- `mutation`: cache key + kill rate.
- `architect_review`: code review notes attesting the classifier
  delegates to the existing extension (rule: extends, not duplicates).
- `qa_test`: spy-based behavior assertion of coordinator routing.
