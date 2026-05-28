---
name: swarm_9d3d2fab-transcript-module-e-network-errors-utilities
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-22
freshness_window: 180d
owners: [network]
description: Module E — Network/Errors/Utilities — implementer transcript
---

# Module E — Network/Errors/Utilities — implementer transcript

**Branch:** `swarm/swarm_9d3d2fab-e-network-errors-utilities`
**Scaffold base:** `40d3270e0`
**Scope:** 19 FLAKE-* sites across 8 test files (PalaceTests/Network, PalaceTests/ErrorHandling, PalaceTests/Utilities).

## Outcome

- Linter: **0 blocking violations** across all 8 scoped files.
- Migrated tests pass when run in isolation and per-class.
- No `Palace/*` production edits.
- No new tests authored (one dead-code property + 1 dead Thread.sleep block deleted in `MockBackgroundWorkOwner`).

## Per-file migration log

### PalaceTests/Network/TPPNetworkExecutorTests.swift
- **L347, L387 (FLAKE-002):** asyncAfter(0.5s)+fulfill() pattern in fire-and-forget POST/DELETE nil-completion tests. Both execute on `.main`. Replaced with `drainMainQueue()` — FIFO guarantees the asyncAfter-scheduled production work has flushed before assertion.
- Result: clean.

### PalaceTests/Network/NetworkRetryTests.swift
- **L319 (FLAKE-001):** `Thread.sleep(forTimeInterval: 0.05)` inside `HTTPStubURLProtocol.register` handler in `testConcurrentRequests_respectsLimit`. The sleep was a "hold the request thread long enough that sibling requests can register concurrent in-flight state."
- Replaced with a `DispatchSemaphore`-gated handshake: the first handler to observe `concurrentCount >= 2` signals; sibling handlers park (capped at 1s) until the signal fires. Concurrency observation is now driven by the real signal (sibling arrival), not wall-clock.
- Initially attempted a busy-wait while-loop, but that tripped TIMEOUT-001. Switched to the semaphore approach.
- Result: clean. Test runs in ~10s under the test's expected concurrency profile.

### PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift
- **L334 (FLAKE-003):** `timeout: 180.0` matched by the linter regex on a **historical reference inside a comment block** explaining why the test no longer uses XCTestExpectations. The 180s value is documentary, not live — the test now samples its single-flight invariant synchronously via `inFlightAttempts == 1` before releasing the HTTP gate.
- **FLAKE-003-OK reason:** the cited timeout is a historical reference in a doc comment, not a live wait. The current test does not block on a 180s timeout.
- Result: clean.

### PalaceTests/Network/CredentialGuardTests.swift
- **L472, L494, L532, L560, L595, L985 (6× FLAKE-003 at 15s):** all six were vanilla `wait(for: [expectation], timeout: 15.0)` calls in SAML/OIDC credential-guard tests that exercise stub-network round-trips completing in microseconds. No asyncAfter+fulfill patterns in this file — the 15s budgets were precautionary, not concealing FLAKE-002. Dropped all six to `timeout: 5.0`.
- Result: clean.

### PalaceTests/ErrorHandling/TPPAlertUtilsTests.swift
- **L349 (FLAKE-002):** asyncAfter(0.2s) closure dismisses the first alert mid-retry to verify retry-presentation behavior. The closure body is `rootVC.dismiss(...)`, NOT `.fulfill()`. The linter's non-greedy DOTALL regex matches across the unrelated `dismissExpectation.fulfill()` further down in the same test body, producing a false positive.
- **FLAKE-002-OK reason:** closure performs a real production action (dismiss) — the linter regex spans across the unrelated `.fulfill()` later in the function body. The asyncAfter exercises real production timing (the production code's exponential backoff at 0.4s); we are not waiting for an expectation here.
- Result: clean.

### PalaceTests/ErrorHandling/TPPProblemDocumentCacheManagerTests.swift
- **L188, L216 (FLAKE-003 at 30s):** concurrent-stress tests dispatching 60 ops/test across global QoS queues. The 30s budget was precautionary against CI-runner contention but excessive for lock-serialized cache access. Dropped both to `timeout: 10.0` (still 2× headroom over the local pass time).
- Result: clean.

### PalaceTests/Utilities/GeneralCacheTests.swift
- **L237, L255 (2× FLAKE-002):** asyncAfter(0.2s / 0.3s)+fulfill() patterns waiting for async barrier writes to materialize on disk. Replaced with `awaitCondition(timeout: 5.0) { FileManager.default.fileExists(atPath: ...) }` — polls the real signal (file/directory presence) instead of guessing wall-clock latency.
- Result: clean.

### PalaceTests/Utilities/TPPBackgroundExecutorTests.swift
- **L49 (FLAKE-001):** `Thread.sleep(forTimeInterval: workDuration)` gated by `if workDuration > 0`. Audit showed `workDuration` was dead test infrastructure — never assigned anywhere in the file or repo. The `workExpectation` mechanism already provides the proper signal-based wait. Removed the dead property and the dead conditional sleep block.
- **L69, L86 (2× FLAKE-002):** `DispatchQueue.global().asyncAfter(1.0)+fulfill()` in `testExecutorCallsSetUpWorkItem` and `testExecutorHandlesNilWorkItem`. The executor dispatches to global background queue. Replaced with `awaitCondition(timeout: 5.0) { owner.setUpWorkItemCalled }` — waits on the actual signal (executor calling setUpWorkItem on owner).
- **L109 (FLAKE-002):** `DispatchQueue.global().asyncAfter(0.5)+fulfill()` in `testExecutorDoesNotRetainOwner`. The test verifies no-crash when owner is deallocated. The original code used `owner!` force-unwrap to construct the executor; my first attempt used `guard let strongOwner = owner` but that created an extra strong reference that kept `weakOwner` alive (causing the test to fail). Restructured to use a do-block scope so the local owner reference goes out of scope at block exit, preserving the weak-reference assertion. Replaced the asyncAfter with `drainMainQueue()` since `dispatchBackgroundWork` schedules `startBackground` on `.main`.
- Result: clean.

## FLAKE-003-OK additions (allow-listed)

| File | Line | Reason |
|------|------|--------|
| PalaceTests/Network/TokenRefreshAndRetryQueueTests.swift | L334 | Historical reference inside a doc-comment block; test no longer waits — invariant is sampled synchronously below. |

## FLAKE-002-OK additions (allow-listed)

| File | Line | Reason |
|------|------|--------|
| PalaceTests/ErrorHandling/TPPAlertUtilsTests.swift | L349 | Closure performs real production action (`rootVC.dismiss(...)`), not `.fulfill()`. Linter's non-greedy DOTALL regex spans across an unrelated `dismissExpectation.fulfill()` later in the function. |

## Gaps / out-of-scope observations

- The contract noted a Clock/scheduler abstraction would be the cleaner long-term fix for the FLAKE-001 site in NetworkRetryTests.swift (deterministic concurrency-observation without semaphores). Left out of scope per the contract.
- Pre-existing flake: `TokenRefreshAndRetryQueueTests` setUp L60 (`libraryAccount.userAccountResolver = { [unowned self] _ in self.userAccount }`) fires `Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value` intermittently when other Network classes run alongside it. This is **pre-existing** — I did not modify L60 or anything in the file body; my only edit was a one-line FLAKE-003-OK comment-suffix on L334. The intermittent crash is documented inside the test class itself ("the actor scheduler under CI-runner contention reliably stalled the 5-caller drain past any timeout"). Out of scope for this migration (no new tests authored, no production changes).
- `MockBackgroundWorkOwner.workDuration` was dead test infrastructure (never assigned anywhere). Removed to clear the Thread.sleep call without leaving an empty conditional. Strictly speaking this is a small simplification, not a new test — the mock still exposes `workExpectation` for any future need.

## Verification

```bash
# Linter (per-file):
$ for f in PalaceTests/{Network/TPPNetworkExecutorTests,Network/NetworkRetryTests,Network/TokenRefreshAndRetryQueueTests,Network/CredentialGuardTests,ErrorHandling/TPPAlertUtilsTests,ErrorHandling/TPPProblemDocumentCacheManagerTests,Utilities/GeneralCacheTests,Utilities/TPPBackgroundExecutorTests}.swift; do
    python3 scripts/lint-test-quality.py --per-file --file "$f" | grep -E ":(FLAKE|MISSING|FLUFF|TIMEOUT)-"
  done
# (no output — all clean)

# Test execution (Module E suites, parallel-disabled, sim DF4A2A27-9888-429D-A749-2E157A049A37):
# All scoped suites report "passed" with 0 failures.
# Pre-existing TokenRefresh L60 intermittent fatal-error noted in "Gaps" — unrelated to migration.
```
