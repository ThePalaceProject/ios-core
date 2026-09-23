---
date: 2026-07-05
pr: "fix/sync-mock-race-segv-bookmark-keys (pre-PR)"
source: shipped-bug
reviewer_ids: []
changeset_id: ""
wall: TDD
walls: [TDD, verify-pr]
severity: high
wall_status: applied
applied_in: "fix/sync-mock-race-segv-bookmark-keys"
detector_script: "scripts/check-unsynchronized-sendable-mock.py"
detector_status: built
no-detector: ""
contributing_docs: []
name: sync-mock-race-segv
type: static
---

# Unsynchronized `@unchecked Sendable` mock + concurrent test = deferred segv blamed on an innocent neighbor

## What escaped

`TPPBookRegistryMock` was `@unchecked Sendable` (the provider protocol is
Sendable) with **unsynchronized** mutable state and a doc comment forbidding
concurrent use. `testConcurrentLocationUpdates_DoNotCrash` violated that
comment: 100 `DispatchQueue.global()` closures mutating
`registry[id]?.location` — racing ARC retain/release on a class-typed
property. The heap corruption detonated in the NEXT test in the class
(`testMultipleSynchronizersWithSameRegistry_DoNotConflict`, itself a
sequential fluff test that can't conflict by construction), which took the
blame in the 2026-07-04 full-suite run: `Test crashed with signal segv`.

Two compounding test-quality failures:
1. The mock lied about its contract — production consumers are entitled to
   concurrent access (production `TPPBookRegistry` is split-lock Sendable);
   the only non-thread-safe implementation of the protocol was the mock.
2. The blamed test's name claimed concurrency its body never performed —
   `XCTAssertNotNil(sync1)` fluff, so the crash attribution was maximally
   misleading (a test that does nothing concurrent "crashed with segv").

## Which walls should have caught it

- **TDD wall** — the fluff test (name/body mismatch, banned
  `XCTAssertNotNil` pattern) predates `check-test-name-vs-body.py`;
  its noun (`Synchronizers…WithSameRegistry`) plus a sequential body should
  ideally have been flagged. The concurrency-hammering test drove ZERO
  production code (mock-only) — a coverage-fluff shape.
- **verify-pr wall** — nothing joined "mock is `@unchecked Sendable` +
  lock-free" with "test drives it concurrently."

## Permanent fix (this PR)

1. `TPPBookRegistryMock` is now lock-backed (single `NSLock`, unlocked
   `_`-helpers for shared work, sends/posts outside the lock) — the mock
   HONORS the provider's Sendable contract.
2. The fluff test rewritten to drive two real
   `TPPLastReadPositionSynchronizer.sync()` calls concurrently via
   `withTaskGroup`; the hammer test annotated as the segv-class regression
   pin.
3. **Detector** `scripts/check-unsynchronized-sendable-mock.py` (+
   `scripts/tests/test_check_unsynchronized_sendable_mock.py`, 6 tests incl.
   clean-diff pass) wired into `verify-pr.sh` as a blocking scan-mode
   Phase 3.5 gate. It joins `@unchecked Sendable`+no-lock mocks against
   concurrent-primitive test files. Deferral marker
   `// unsync-sendable-mock-deferred: <reason>` supports triaged survivors.

## Survivors triaged at detection time

- `TPPUserAccountMock` — **LIVE, not latent** (blast-radius reviewer,
  Phase 4): `TPPCredentialConcurrencyTests`
  (TPPCredentialVisibilityTests.swift:693-771) already hammers the shared
  mock from 50–100 threads (`refreshCredentialsFromKeychain` ×50 concurrent)
  — the same segv class as this entry, active today. 18 unsynchronized vars,
  wide SignInLogic blast radius → **scope-deferred** with marker + this
  entry as the tracking record. **RESOLVED 2026-07-06
  (fix/useraccount-mock-lock):** locked with the same recipe plus two
  subclass-specific rules — production-locked members (`signInGeneration` →
  controlLock) touched only OUTSIDE mockLock (one-directional nesting), and
  derivations that previously called overridable members (`hasCredentials()`
  → overridden `credentials`) now use the pure
  `UserAccountAuthHelper.hasCredentials(_:)` on locked snapshots. The
  mutable `static shared` (the F-008 race vector) got its own `sharedLock`.
  Deferral marker removed; detector re-covers this mock.
- `MockFeatureFlagProvider`, `MockPDFDocumentMetadata`, `MockReachability` —
  latent (no concurrent usage today); detector reports as notes, `--strict`
  escalates.

## Lesson

`@unchecked Sendable` on a mock is a *contract claim*, not a compiler
silencer. If the production implementation is thread-safe, the mock must be
too — otherwise every concurrency test through the protocol is UB, and the
failure will be attributed to whichever test runs next. Found via Heka
dogfood: `harness test` honest-red (2026-07-04) + rigor churn-map
cross-reference.
