---
name: swift6-apptarget-borrow-return
created: 2026-06-30
author: Maurice Carrier
branch: swift6/apptarget-borrow-return
priority: Swift 6 app-target modernization (Wave 1, targeted strict-concurrency) — borrow/return critical-path slice
---

# Intent: drive borrow + return flows to zero `targeted` strict-concurrency warnings

## Context

`SWIFT_STRICT_CONCURRENCY = targeted` is set on the Palace app target (warnings,
not errors; `SWIFT_VERSION` stays 5.0). This slice fixes the borrow + return
critical-path files by ISOLATION (never `nonisolated(unsafe)`), with no
control-flow change so the existing `BorrowOperationContractTests` /
`BookReturnServiceContractTests` ordered-call-order snapshots do not drift.

Baseline warnings (origin/develop):
- `BorrowOperation.swift` L370,392,413,500,505,530,535 (capture of self) and
  L456,697,928 (capture of self?) — all `capture of 'self'` in `@Sendable`
  (`Task` / `MainActor.run` / `withTimeout`) closures.
- `BookReturnService.swift` L292,302,308,317,340 (capture of self); L294,309,318
  and L334(x2),471 (capture of non-Sendable `completion`).
- `BookSignInRedirectHandler.swift` L203 (capture of self?).

## Claims

- `BorrowOperation` conforms to `@unchecked Sendable` with a documented Sendable
  invariant (all deps `let`; only mutable instance member `weak var delegate` is
  wired once at owner construction; circuit-breaker state is `static` + NSLock).
- `BookReturnService` conforms to `@unchecked Sendable` with a documented
  invariant (`inFlightTasks` guarded by `inFlightLock`; `delegate` wired once).
- `BookSignInRedirectHandler` conforms to `@unchecked Sendable` with a documented
  invariant (`delegate` wired once; `credentialRequestState` already
  `@unchecked Sendable`).
- `BookReturnService.returnBook(withIdentifier:completion:)` and its private
  helpers (`handleReturnWithoutRevokeURL`, `handleRevokeError`,
  `presentReturnFailureAlert`, `performPostReturnSyncThen`) take a `@Sendable`
  completion so the closure threads through the async return state machine
  without a non-Sendable capture.
- `MyBooksDownloadCenter.returnBook(withIdentifier:completion:)` and
  `BookDetailViewModel.didSelectReturn(for:completion:)` take a matching
  `@Sendable` completion (1-line additive signature changes — the two
  cross-file call sites the @Sendable completion ripples into).

## Anti-claims

- No control-flow / call-order change in any borrow or return path; the existing
  contract-snapshot tests remain valid and are NOT re-recorded.
- No shared-type change: `TPPBook`, `TPPBookState`, `TPPBookRegistryProvider`,
  `TPPUserAccount` are NOT modified (TPPBook/CredentialRequestState are already
  `@unchecked Sendable` on develop).
- No new functions, enum cases, public API surface, or state machine added.

## Verification

- Cannot build the app target locally (private Adobe DRM headers absent). CI is
  the build gate per the modernization plan; the orchestrator pushes to CI.
- Static DoD checks run clean locally: `check-blast-radius.py` (exit 0),
  `check-superpartner-spectrum.py` (exit 0), `check-adjacency-staleness.py`
  (exit 0).
- Changes are pure isolation annotations with zero runtime-behavior change, so
  no new test is required; the `BorrowOperation` / `BookReturnService` contract
  snapshots already pin the ordered dependency calls and would fail on drift.
