---
name: profile doc expired token gate
author: maurice.carrier
created: 2026-09-08
type: bugfix
risk: critical_path
---

# An expired bearer token was sent to `/patrons/me/`, and read back as "signed out"

## Motivation

`getProfileDocument` gated its request on `hasCredentials()`, which is
`hasAuthToken || hasBarcodeAndPIN` — it answers "is something stored", not "will
it work". An **expired** token satisfies it, so the request goes out and the
server answers 401 with the same OPDS auth-document body the gate exists to
avoid. The app reads that back as a signed-out patron.

Presence is not validity, but the naive fix — block every expired token — is
also wrong, and that is the whole difficulty. The 401 refresh is REACTIVE and
lives in the response delegate: `TPPNetworkResponder.handleExpiredTokenIfNeeded`
marks the credential stale and calls `refreshTokenAndResume(task:)`, which stores
a fresh token and re-drives the task, so the profile fetch succeeds. Blocking
every expired token deletes a repair that works today, for exactly the
credentials it can fire on.

So the gate has to distinguish "expired" from "expired and unrepairable".

## Reproduction

1. Sign in to a token-auth library (a Palace library whose auth document declares
   `http://thepalaceproject.org/authtype/basic-token`).
2. Let the stored bearer token pass its expiry, or set `expirationDate` into the
   past.
3. Foreground the app, or trigger any path that calls `getProfileDocument` —
   `NotificationService.updateToken()` / `deleteToken(for:)` run it on every
   account-change rehydration, so a cold relaunch is enough.

Observed: the request goes out with the expired bearer token, the server answers
401 with an OPDS auth-document body, and the app parses that body and presents
the patron as signed out.

Original field report is the `/patrons/me/` 401 storm at cold relaunch
(PP-4164 → F-007, refined by F-DG5-002 via chaos-qa dogfood-5).

## Root cause

`hasCredentials()` is `hasAuthToken || hasBarcodeAndPIN`. It answers "is
something stored", not "will it work", so an expired token passes the gate and
the request is issued.

The non-obvious half is why the naive fix is also wrong. The 401 refresh is
REACTIVE, not pre-flight: `TPPNetworkResponder.handleExpiredTokenIfNeeded` marks
the credential stale, calls `refreshTokenAndResume(task:)`, stores a fresh token
(which writes `.loggedIn` and heals the stale flag) and re-drives the same task.
That path never consults `enableTokenRefresh`. So blocking every expired token
deletes a repair that works today, for precisely the credentials it can fire on:
`isTokenExpired` is non-false only for `.token` with a non-nil expiry, and that
expiry is written by the barcode/PIN→token exchange, which is exactly the shape
the reactive refresh repairs.

The gate therefore has to separate "expired" from "expired AND unrepairable",
which is what `isTokenRefreshRequired()` answers.

A second root cause sits underneath, and is why this took several rounds: the
decision was not observable. `getProfileDocument` reached the executor through
`AppContainer.production()` and read its account from the process-wide cache, so
no test could see whether a request was issued or stage the credentials that
would make it issue. The original F-007 guard asserted a nil document and
sub-second timing against `example.invalid` — both true whether or not the
request went out — and survived deleting the entire gate.

## Claims (what the diff WILL deliver)

1. **A pure, falsifiable gate.** `Account.canAuthenticateProfileRequest(hasCredentials:tokenHasExpired:tokenRefreshWillRepair:)`
   returns false only when credentials are absent, or the token has expired AND
   no refresh can repair it. Expressed as a function of three booleans so the
   decision is testable without networking.

2. **Two injected seams on `getProfileDocument`.** `performRequest:` makes
   "was a request issued" observable; `userAccount:` makes the credential state
   stageable. Both default to nil and resolve to production behaviour.
   The second exists because without it the first can only ever be driven in the
   no-credentials direction — the account was read from the process-wide cache
   inside the method, so no test could stage an expired-but-repairable token.

3. **The gate is driven in BOTH directions.** An expired-but-refreshable token
   MUST still issue the request; an expired-and-unrepairable one must not. The
   positive arm is the one that kills the additive mutant
   `if userAccount.authTokenHasExpired { completion(nil); return }` inserted
   above the gate — verified by reintroducing that mutant and observing the test
   fail by name.

4. **OIDC re-auth extracted to `Palace/MyBooks/OIDCReauth.swift`.** A
   presentation failure (`ASWebAuthenticationSessionError` code 3,
   `.presentationContextInvalid`) is OURS and is retried once; a patron
   cancellation (code 1) is a decline and is never re-presented. The retry loop
   is driven through an injected `present:` seam and asserted on the observed
   presentation COUNT, because a source-text lint is monotone — it detects
   deletion but never insertion or reordering, and two mutants already defeated
   the lint-based version.

5. **The non-token branch of `isTokenRefreshRequired` gets bracketing tests.**
   Previously every fixture was token-auth or nil, so that arm was unreached and
   a reviewer's `return true` mutant there was undetectable.

## Anti-claims

- Does **not** change behaviour for barcode/PIN credentials, for tokens with no
  expiry date, or for OIDC (which stores no expiry). `isTokenExpired` is false
  for all three, so those callers are unaffected.
- Does **not** change anonymous-library behaviour beyond the pre-existing
  no-credentials skip.
- Does **not** alter `TPPNetworkResponder`'s reactive 401 refresh, and does not
  reuse its predicate. The two differ today (the responder requires
  `tokenURL != nil` in every arm; `isTokenRefreshRequired`'s non-token branch
  does not). That divergence is unreachable through production sign-in paths and
  is left alone. Not absolute: `DeveloperSettingsViewModel.swift:862`
  ("simulate stuck state") writes an expired token onto `currentUserAccount`
  regardless of `authType`, which on a SAML/OIDC/basic library yields
  `tokenExpired && !isToken` — the gate allows the request while the responder's
  browser-auth bypass performs no repair. That affordance exists to simulate
  breakage and is debug-menu only, so it is not a defect, but "unreachable"
  without the qualifier was wrong.
- Does **not** remove the dead `isOAuthAndNeedsRefresh` conjunct in
  `isTokenRefreshRequired`. It requires `isOauth && tokenURL != nil`, but
  `tokenURL` is assigned non-nil in exactly one arm — `case .token`
  (`Account.swift:189`) — so `isOauth` implies `tokenURL == nil` and the term
  can never be true. It is pre-existing, this diff only calls the helper, and
  removing it would move a refresh predicate on the critical path with no defect
  driving it. Documented in the tests instead.
- Does **not** add production surface reachable outside tests: both seams
  default to nil and production passes nothing.
- Does **not** change the OIDC retry BOUND (two presentations maximum) or make
  re-auth unbounded.

## Files in scope

- `Palace/Accounts/Library/Account+profileDocument.swift`
- `Palace/MyBooks/BorrowOperation.swift`
- `Palace/MyBooks/OIDCReauth.swift`

## Verification

- `AccountProfileDocumentTests` — 23 tests, both gate directions through the
  seams, plus the states-by-events table for the three-boolean predicate.
- `OIDCReauthRetryBehaviorTests` — retry/consent driven through the presentation
  spy, asserting observed presentation count.
- `OIDCReauthAttemptTests`, `WebAuthPresentationAnchorTests`.
- Mutation, both changed production files (this said "the changed production
  file", singular, and there are two):
  - `Account+profileDocument.swift` — 2 points, 2 killed, 0 survived, 0 errored,
    0 uncovered, baseline PASS.
  - `OIDCReauth.swift` — 15 points, 8 killed, **0 survived**, 0 errored, 7
    uncovered. The uncovered are the URL-building guards, the callback parser and
    the post-loop total-function return: none is drivable without a real
    `ASWebAuthenticationSession`. Zero survivors is the number that matters.
- The headline mutant reintroduced by hand and observed to fail by name, then
  reverted and observed green. A green suite is evidence only if red was
  possible.
