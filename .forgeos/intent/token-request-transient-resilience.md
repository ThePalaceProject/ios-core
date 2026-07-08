---
name: token-request-transient-resilience
created: 2026-06-08
author: Maurice Carrier
---

# Intent: make login token exchange resilient to transient failures (HelpSpot 18046)

## Context

HelpSpot 18046 (Whiting Library / Green Mountain Library Consortium, iOS 3.1.0):
patrons see "unrecognized/invalid credentials" on VALID credentials at login,
which clears after 2-3 identical retries; Palace support reproduced it.

Root cause (code scan): `TokenRequest.execute` (the Basic-Auth POST to /token
in the login path `getBearerToken → executeTokenRefresh → TokenRequest.execute`)
treats ANY non-200 as a hard failure with NO retry. `userFacingSignInError`
then maps a failure lacking a problem document and lacking a client-side
`URLError` to the DEFAULT "Invalid Credentials". So a transient server-side
non-200 (intermittent 401 or 5xx) is misreported as bad credentials. This
behavior is unchanged since 3.0.x — NOT a 3.1.0 regression — but the resilience
fix resolves the patron-visible symptom regardless of the backend transient.
Targeting 3.2.0 (→ develop).

## Claims

- Adds bounded retry-with-backoff to `TokenRequest.execute` for TRANSIENT
  failures only: HTTP 408/429/5xx and retriable `URLError`s (timeout, connection
  lost, cannot-connect, DNS). Genuine auth failures (401/403) and other 4xx are
  NOT retried. Backoff + max-attempts are injectable so tests run fast.
- Adds pure, testable helpers `TokenRequest.isTransientStatus(_:)` and
  `TokenRequest.isRetriableURLError(_:)`.
- Adds transient-server discrimination to `userFacingSignInError`: a transient
  HTTP error (408/429/5xx) surfaces the EXISTING network-unavailable copy
  ("try again"), not "Invalid Credentials" — no new user-facing copy.

## Anti-claims

- Does NOT change the credentials sent, the auth document flow, or the 200/decode
  success path.
- Does NOT retry genuine 401/403 (bad creds) — those still surface immediately.
- Does NOT add new user-facing copy (reuses the network-unavailable strings).
- Does NOT change `performForceReset` / sign-out / borrow / download.

## Files in scope

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TokenRequest.swift` (retry + helpers)
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` (`userFacingSignInError` discrimination)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/...` (retry + helper tests)
- `PalaceTests/SignInLogic/...` (error-discrimination test)
