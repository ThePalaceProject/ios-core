# Finding + handoff: keychain-hermetic AudiobookLoaderOPDSShapeMatrixTests (post-3.2.0)

**Branch:** `fleet/w-lane-keychain-hermetic` (off develop). **Priority:** post-3.2.0
fast-follow hardening; merges after M0. **Status:** land-ready, test-only,
red-first design-complete. Full verify-pr intentionally NOT run (held during M0).

## Mechanism

`AudiobookLoader.load()` (`Palace/Audiobooks/AudiobookLoader.swift:70`) runs
`refreshTokenIfNeeded(for:)` (:137) BEFORE the adapter chain (`resolveSource`,
:111). The gate reads `AppContainer.production().accountsManager.currentUserAccount`
and trips when `authTokenHasExpired == true`, i.e. when the current account holds
a `.token` credential whose `expirationDate <= now`
(`UserAccountAuthState.isTokenExpired`). On a trip with no refreshable
credentials it returns `.missingCredentialsForTokenRefresh` and the adapter chain
is SKIPPED — so in `AudiobookLoaderOPDSShapeMatrixTests` every spy's
`resolveCallCount` is 0 and the routing assertions fail `0 != 1`.

## Why post-3.2.0 (not an M0 in-suite leak)

Only two tests write an EXPIRED token to the shared account —
`AccountDetailViewModelTests.testIsSignedIn_trueWhenOAuthCredentialsStale`
(sets `expired_token`, clears via `account.removeAll()` at end of test) and
`ColdStartResumeIntegrationTests.testColdStart_TokenPastExpiry`
(clears via `tearDownWithError → removeAll()`). Both clean up on NORMAL
completion, so a normally-finishing CI run leaves no leak. The observed reds were
INHERITED dirty-start state: a suite killed mid-run (e.g. `TaskStop`/`kill -9` on
a verify-pr run) can land between `setAuthToken(expired)` and the writer's
`removeAll()`, leaving an expired token in the sim keychain that a later run
inherits. Confirmed by a controlled A/B/C experiment (clean cold build + dirty
sim still fails; same build + `simctl keychain reset` passes). Practical risk is
already mitigated by devops' per-spawn keychain reset.

## Implemented fix (this branch)

Test-only, in `AudiobookLoaderOPDSShapeMatrixTests`:
- `setUpWithError`: `try KeychainAvailability.skipIfUnavailable()` then
  `AppContainer.production().accountsManager.currentUserAccount.removeAll()` —
  the production sign-out/clear API (NOT raw `SecItemDelete`). Makes
  `authTokenHasExpired == false` deterministically so the gate passes.
- `tearDown`: same clear (good-citizen, leaves clean baseline).
- Red-first self-proving test
  `testHermeticGuard_clearingExpiredToken_unblocksAdapterRouting`: sets an
  expired token in-body, clears it, asserts `authTokenHasExpired` flips
  `true → false` AND `openAccess.resolveCallCount == 1`. No-op the clear → red.

## Scope correction — LocalFileAdapterTests EXCLUDED

`LocalFileAdapterTests` is fully constructor-injected (`StubDownloadCenter`,
`StubFileReader`, `StubTokenRefresher`) and references no
`AppContainer.production()` / `currentUserAccount` / keychain / token state.
`LocalFileAdapter` is hermetic by construction, so the keychain reset does NOT
apply (would be cargo-cult). If `LocalFileAdapterTests` had a run-A red, it has a
DIFFERENT root cause and needs separate characterization.

## How to verify (post-3.2.0)

```bash
xcrun simctl keychain <sim-udid> reset   # establish a clean baseline
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=<sim-udid>' \
  -only-testing:PalaceTests/AudiobookLoaderOPDSShapeMatrixTests test
```
Red-first: comment the in-body `account.removeAll()` in the hermetic test → it
fails; restore → passes. Then run full `scripts/verify-pr.sh --quick`.
