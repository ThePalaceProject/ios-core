---
name: keychain-hermetic-audiobook-matrix-tests
created: 2026-06-11
author: Maurice Carrier
branch: fleet/w-lane-keychain-hermetic
priority: post-3.2.0 hardening (merges after M0 + real M0-scope items)
---

# Intent: make the audiobook adapter-routing tests hermetic against inherited sim keychain auth state

## Context

`AudiobookLoaderOPDSShapeMatrixTests` and `LocalFileAdapterTests` are
sim-keychain-state-dependent. `AudiobookLoader.load()` runs
`refreshTokenIfNeeded(for:)` BEFORE the adapter chain (`resolveSource`); that
gate reads `AppContainer.production().accountsManager.currentUserAccount`. When
the current account holds a leftover EXPIRED token (a `.token` credential whose
`expirationDate <= now`), `authTokenHasExpired == true`, the token-refresh path
fails (`.missingCredentialsForTokenRefresh`), and the adapter chain is SKIPPED —
so every spy adapter's `resolveCallCount` is 0 and the routing assertions fail
`0 != 1`.

Characterization (accepted by coordinator): this is NOT a deterministic in-suite
leak. The only two tests that write an EXPIRED token to the shared account —
`AccountDetailViewModelTests.testIsSignedIn_trueWhenOAuthCredentialsStale` and
`ColdStartResumeIntegrationTests.testColdStart_TokenPastExpiry` — both clear it
via `removeAll()` on normal completion, so a normally-finishing run leaves no
leak. The reds came from INHERITED dirty-start state: a suite killed mid-run can
land between `setAuthToken(expired)` and its `removeAll()`, leaving an expired
token in the sim keychain that a later run inherits. Hence this is post-3.2.0
DEFENSE-IN-DEPTH hardening, not M0-blocking.

Test-only change. No production-code change.

## Claims

- Adds a `setUpWithError`/`tearDown` to `AudiobookLoaderOPDSShapeMatrixTests` and
  `LocalFileAdapterTests` that clears the shared current account's auth state via
  the production sign-out/clear API
  (`AppContainer.production().accountsManager.currentUserAccount.removeAll()`),
  guarded by `KeychainAvailability.skipIfUnavailable()`. This makes
  `authTokenHasExpired == false` deterministically, so the token gate passes and
  the adapter chain runs regardless of inherited sim keychain state.
- Adds a red-first self-proving test that sets an expired token in-body, calls
  the reset, and asserts `authTokenHasExpired` flips `true -> false` AND the
  adapter routes (`resolveCallCount == 1`).

## Anti-claims

- Does NOT change `AudiobookLoader` or any production code — the token-gate
  ordering and routing behavior are untouched.
- Does NOT use raw `SecItemDelete`; uses the production account-clear API.
- Does NOT change the existing routing assertions in the matrix tests.

## Files in scope

- `PalaceTests/Audiobook/AudiobookLoaderOPDSShapeMatrixTests.swift`

## Scope correction (investigated, EXCLUDED)

- `PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift` — EXCLUDED. It is
  fully constructor-injected (`StubDownloadCenter`, `StubFileReader`,
  `StubTokenRefresher`); it does NOT reference `AppContainer.production()`,
  `currentUserAccount`, the keychain, or `authTokenHasExpired`. `LocalFileAdapter`
  is hermetic by construction, so the keychain reset does not apply and would be
  cargo-cult. Its run-A red (if real) has a DIFFERENT root cause and needs
  separate characterization — flagged to the coordinator.
