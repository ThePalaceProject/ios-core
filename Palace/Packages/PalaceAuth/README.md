# PalaceAuth

Pure-Swift authentication primitives extracted from `Palace/SignInLogic/`. Hosts the auth state machine reducer (`AuthReducer`), `TokenRequest` (Basic-Auth bearer-token exchange), the SAML helper's protocol-based core (`TPPSAMLHelper`), front-end input validation (`TPPUserAccountFrontEndValidation`), the `URLResponse` re-auth classifier extension, and (3.2.0 swarm_66819d80) the input-driven `AuthErrorClassifier` + `AuthCoordinator` actor.

Depends on `PalaceLogging`, `PalaceNetwork`, and `PalaceCatalog`. Heavy main-target collaborators (`TPPSignInBusinessLogic`, `Account`, `AccountsManager`, `TPPUserAccount`) stay in the app target and are reached through narrow public protocols (`UniversalLinksProviding`, `TPPLibraryAccountReadable`, `TPPSignInValidationContext`, `SAMLAuthContext`, `SAMLWebViewPresenting`, plus the coordinator's `Reauthenticating`, `SignInModalPresenting`, `TPPUserAccountReading`, `TPPUserAccountWriting`, `TPPCurrentLibraryAccountProviding`) declared in this package.

## 3.2.0 auth-decision surface (swarm_66819d80, Module A)

The single seam every network consumer and every re-auth caller will hit
in 3.2.0:

```swift
// 1. Classify the response — pure, IdP-agnostic.
let classifier = AuthErrorClassifier()
let outcome = classifier.classify(
    response: httpResponse,
    problemDocument: parsedDoc,
    body: rawBody,
    originalRequestURL: originalURL  // preserves the cross-domain CDN guard
)

// outcome is one of:
//   .ok                              — 2xx or cross-domain 401 carve-out
//   .reauthRequired(reason: ...)     — 401 with optional reason hint
//   .forbidden(reason: ...)          — 403 with specific reason
//   .serverError(status: Int)        — 5xx (and other non-auth non-2xx)
//   .networkError                    — transport failure (nil response)

// 2. Dispatch through the coordinator — IdP-aware, single-flighted.
if case .reauthRequired(let reason) = outcome {
    let result = await coordinator.refreshCredentialsIfNeeded(reason: reason)
    switch result {
    case .success:
        // retry the original request
    case .failure(.userCancelled):
        // user dismissed the modal — propagate to UI
    case .failure(.noActiveAccount):
        // no library selected — caller does its own fallback
    case .failure(.refreshAlreadyFailed):
        // cooldown active — surface the prior failure rather than retry
    case .failure(.unsupportedAuthenticationType):
        // future mechanism — caller falls back to legacy path
    }
}
```

The coordinator's dispatch matrix (from `docs/3.2.0-auth-idp-catalog.md`):

| Mechanism            | Routing                                  |
|----------------------|------------------------------------------|
| SAML                 | always modal (no client-side refresh)    |
| OIDC                 | always modal (no client-side refresh)    |
| OAuth-intermediary   | always modal (partner callback flow)     |
| Basic                | silent for `.expiredToken`, else modal   |
| Token                | silent for `.expiredToken`, else modal   |

Silent refresh failure falls back to modal automatically. Concurrent
`refreshCredentialsIfNeeded` calls during an in-flight refresh join the
existing task (single-flight). A failed refresh enters a 30s cooldown
where subsequent calls short-circuit to `.refreshAlreadyFailed` — this
prevents the bearer-token refresh loop where every 401 retry kicks off a
fresh refresh attempt.

The classifier delegates the recoverable/unrecoverable + cross-domain
decisions to the existing `URLResponse+TPPAuthentication` extension; it
does NOT duplicate that logic. See `AuthErrorClassifier.swift` header for
the delegation map.

## Test surface

- `PalaceAuthSmokeTests` — `AuthReducer` smoke (`signOutCompleted`, `refreshAuthStarted`).
- `AuthErrorClassifierTests` — 33 per-row unit tests (one per grounded row in `docs/3.2.0-auth-idp-catalog.md`).
- `AuthErrorClassifierPropertyTests` — 200 trials/run with 7 invariants from the catalog § "Property-based generator inputs".
- `AuthCoordinatorTests` — 23 spy-driven dispatch / single-flight / cooldown tests.
- `AuthCoordinatorWiringTests` — round-trip lifecycle through the public seam (per CLAUDE.md § "State-machine wiring tests").

Main-target test bundles (`URLResponseAuthenticationTests`, `CrossDomain401Tests`, `AuthErrorCategoryTests`) continue to assert the legacy `indicatesAuthenticationNeedsRefresh(...)` boolean — the new classifier does NOT replace those tests, it builds on top of them.
