---
name: fix-remote-config-fetch-timeout-firebase-unbounded-await
created: 2026-06-10
author: claude-opus-4-8
tracking: unblocks PR #1053 (per-test timeout) — last hard hang after the #1061 foundational fix
related_prs: []
---

# Intent: bound the remote-config fetch so it can't hang the caller

## Problem
`FirebaseManager.fetchAndActivateRemoteConfig()` does `try await
remoteConfig.fetchAndActivate()` with no upper bound. Firebase's
`fetchAndActivate()` can stall indefinitely when the network is dead/slow, or —
in unit tests — when Firebase is not configured, leaving the `await` suspended
forever. `RemoteFeatureFlags.shared.fetchIfNeeded()` awaits this, so
`RemoteFeatureFlagsTests.testFetchIfNeeded_doesNotCrash` intermittently hung
>2min and was killed by PR #1053's per-test timeout (the last hard hang after
the #1061 awaitReady-leak fix cleared the pool-starvation class). A real user on
a dead network would likewise hang the flag fetch.

## Claims
- `fetchAndActivateRemoteConfig()` wraps the fetch in `Self.withTimeout(seconds:
  Configuration.fetchTimeoutSeconds /* 10 */)`; on timeout it logs and returns
  `false` (proceeds with cached/default config).
- `withTimeout` is a generic `static` helper (races the operation against a
  `Task.sleep`, cancels the loser, throws `RemoteConfigFetchTimeout` on timeout),
  made `internal` so tests can pin it deterministically.
- Two deterministic tests: `testWithTimeout_boundsAHangingOperation` (a 10s
  inner hang is bounded under 2s and throws the timeout) and
  `testWithTimeout_returnsResultOfFastOperation` (a fast op returns its value, no
  false timeout).

## Anti-claims
- No XCTSkip / no relaxed test timeout / no test-environment special-casing — the
  bound is a real PRODUCTION robustness improvement that also resolves the test
  hang.
- No change to the flag values returned, the rate-limiting, or the `isFetching`
  single-flight guard.

## Files in scope
- `Palace/AppInfrastructure/FirebaseManager.swift`
- `PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift`
