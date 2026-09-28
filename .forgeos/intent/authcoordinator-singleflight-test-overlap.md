---
name: authcoordinator-singleflight-test-overlap
created: 2026-09-28
author: Maurice Carrier
---

# Intent: make the AuthCoordinator single-flight tests establish the overlap they assert

## Context

PR #1523 wired the PalaceAuth package tests into CI for the first time since
2026-05-12. Their first run failed the coordinator single-flight test with two
silent re-authentications where one was expected; CI named the telemetry
sibling instead. Both tests fire two concurrent refreshes against a stub that
returns without suspending, so nothing forces the calls to overlap. Under load
the first flight completes and clears its slot before the second caller
reaches the actor, and the second caller correctly starts a new flight.

Measured on a scratch copy, 3 x 200 iterations: 9% of runs counted two
refreshes; with the stub held open 20 ms, 0 of 600; strictly sequential, 600
of 600. The production guard is correct.

## Claims

- The in-flight single-flight tests hold the stubbed refresh open with a gate
  and release it only after the coordinator reports the second caller joined,
  so the overlap is established rather than assumed.
- AuthCoordinator records how many callers joined an in-flight refresh, as an
  internal read-only counter bumped on the join branch. It is a lifetime count
  per coordinator instance; every test builds its own coordinator, so no reset
  is needed. It exists because a join is otherwise unobservable.
- Every wait in the single-flight helper is bounded, and the gate is released
  on every path, so a regression that stops the refresh reaching the stub
  fails the test by name instead of hanging it.
- Each in-flight test is paired with a sequential test asserting two flights,
  so a slot that is never cleared is caught as well as a join that never
  happens.

## Anti-claims

- Does NOT change refresh dispatch, the single-flight guard, the failure
  cooldown, telemetry emission, or any public API.
- Does NOT touch the app target or any network code.
- Does NOT claim a test guards against a future suspension point being added
  between the in-flight check and the task registration; that invariant is
  held by the code having none.

## Files in scope

- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` (join counter, reset)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/RefreshGate.swift` (gate + join helper)
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthCoordinatorTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthTelemetryEmissionTests.swift`
