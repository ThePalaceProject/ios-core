# Full-Suite Test-Pollution Investigation — Handoff

**Status:** Unsolved (systemic). Green-board enforcement deferred. All targeted fixes below are landed and SoD-approved — they close real mechanisms but do **not** converge the aggregate. This doc exists so a fresh investigation starts from here, not from scratch.

**Branch:** `fix/accounts-authdoc-late-write-test-isolation` (PR #1232). CI job: GitHub Actions "Unit Tests" workflow → `build-and-test`.

---

## TL;DR

Removing the CI "green-wash" (a gate that let a red suite report green) revealed that the Palace test suite has a **broad, non-deterministic, CI-load-dependent flaky pool**: ~8–13 async tests fail per full-suite run, but **the failing set shifts almost entirely run-to-run**, and *correct, targeted fixes to real leak mechanisms do not reduce the aggregate count*. This is the signature of systemic cross-test pollution over shared global state in a **serial ~7,000-test single-process run**, not a handful of fixable sources.

**Recommended next approach:** stop chasing individual leak sources; pursue **test-execution isolation** (process/shard isolation so global state cannot bleed) and/or a **systematic hermeticity audit** (enumerate every process-global mutable resource and register a `_resetForTesting` for each). See "Recommended approach."

---

## The green-wash (this part IS solved — enforcement deferred, not lost)

`scripts/xcode-test-optimized.sh` runs `xcodebuild test -retry-tests-on-failure -test-iterations 3`, which **exits 0 even when tests fail all 3 iterations**. The workflow's `Fail if tests failed` gate keyed only on `steps.tests.outcome == 'failure'`, so a red suite reported green (`steps.tests.outcome == 'success'`; gate skipped).

**Fix (works, verified):** gate additionally on the parsed xcresult `summary.failed > 0` from `test-data.json` (written by the existing `Parse Test Results` step), while preserving the retry-as-flake-safety contract (a retry-passed test has a final-pass result → not counted). This was landed then **reverted to defer enforcement** (the un-mask makes the board honestly red on the pre-existing pollution, which blocks everything until the pollution is fixed). The enforcement patch lives in git history (commit `041ef99b0`) for revival once the suite is genuinely green. **Reviving it is the finish line.**

---

## Evidence: the trajectory (7 full-suite CI runs)

Each row is a full-suite CI run after a fix. "Failed" = distinct tests failing all 3 retries (the gate's `summary.failed`).

| Run | Fix applied that round | Failed | Notable victims (shift every run) |
|----|----|----|----|
| 1 | (baseline, un-masked gate) | 9 | CatalogViewModelStateMachineTests ×6 (timeouts), AccountsManagerLaunchSnapshotTests, AccountsManagerStateMachineWiringTests |
| 2 | (dismiss-branch test etc.) | 8 | CatalogViewModelStateMachineTests, Accounts, Borrow |
| 3 | global weak-registry drain-all | 10 | CatalogViewModelStateMachineTests back, Borrow, DownloadTransferRetry |
| 4 | completion-handler write guards | 8 | **Zero Accounts/Catalog** — ImageCacheContinuationTests, DownloadTransferRetry, BorrowAndDownloadIntegration, MyBooksDownloadCenter |
| 5 | crawler cancellation-responsiveness | 12 | Catalog cluster **reappeared**, Accounts, Download |
| 6 | MockBackend + Chaos reset registration | 13 | **crashed short run** (no xcresult), incl. my own reset-probe tests |

**Key observations:**
- Count is stuck ~8–13, **non-decreasing** (arguably drifting up).
- The victim *set* is almost entirely different each run — including "fixed" clusters reappearing (run 4 had zero Accounts/Catalog; run 5 had them back).
- Two symptom types: **timeouts** ("Timed out waiting for `.loaded`", 5s/15s — a hung async continuation) and **assertion corruption** (wrong payload / stale state).
- A run's WS0 pool-probe breadcrumbs (`[WS0-POOL-DIAG] … pool-probe latencyMs=…`) were mostly healthy (24–288ms), i.e. it is NOT uniform pool starvation — it's concentrated events.

---

## Root-class finding (from PR #1119 — the smoking gun)

PR #1119's commit body describes **this exact symptom**:

> *"ImageCacheContinuationTests is the only test that suspends `ImageCache.shared.processingQueue`, and it was restored solely by that test's tearDown. If the test ever aborted mid-suspend, the global queue stayed suspended and every later `ImageCache.shared.getAsync` hung to timeout — surfacing as a different flaky victim each full-suite run (the isolation-family signature; e.g. the ImageCacheContinuationTests + moving-target reds)."*

So the root class is: **a process-global mutable resource that a test puts into a bad state (suspended queue, active mock-scenario, stale in-flight map, non-empty fault plan) and restores only in its own tearDown. If that test aborts before tearDown (timeout, crash, throw, or a shuffle interleave), the resource stays broken process-wide, and every later test that touches it hangs or gets corrupted — a different victim each run.**

The codebase's **established, working mechanism** for this is `SingletonResetRegistry` + a finished-test observer (`PalaceSingletonResetObserver.testCaseDidFinish` → `invokeAll()`), which restores a resource after **every** test regardless of tearDown. #1119 wired `ImageCache._resetForTesting` this way. **The moving-target reds persist because more process-globals have the same hazard and aren't yet registered.**

**Already-registered resetters** (`PalaceTests/PalaceTestSetup.swift` `registerBuiltInResetters`, ~:117-159): `AppContainer._resetForTesting`, `AccountStateStore.shared._resetAllForTesting`, `TPPUserAccountMock.resetShared`, `HTTPStubURLProtocol.removeAllHandlers`, `URLSession._resetStubbedSession`, `ImageCache._resetForTesting`, plus the **now-added** `MockBackendURLProtocol._resetForTesting` and `ChaosURLProtocol.reset` (this branch).

---

## Bounded hazard list (reset-registration candidates)

The investigation judged this **convergeable via reset-registration** (a bounded set), but round-6 CI did **not** confirm convergence (count went up; the run crashed). Treat "bounded/convergeable" as **unverified** — the crash suggests either the probe was bad OR the hazard set is larger/deeper than mapped.

1. **`MockBackendURLProtocol`** (`Palace/Settings/Debug/MockBackend/MockBackendURLProtocol.swift`) — process-global `activeScenario`/`scopedHost`/`fixtureDirectoryPath`/`fixtureBundle`. If leaked, `canInit(with:)` intercepts **every** later request → fixture/canned-401 corruption. **Reset registered this branch (KEPT).** Highest-confidence, but did not visibly converge.
2. **`ChaosURLProtocol`** (`PalaceTests/Chaos/ChaosHarness.swift`) — static `_plan`/`_requestCount`; leaked fault plan faults later requests. **Reset registered this branch (KEPT).**
3. **OPDS feed caches** — `OPDS2FeedCache.shared` / `OPDS1FeedCache.shared` (`Palace/OPDS2/Cache/OPDSFeedCache.swift`), `UnifiedOPDSService.shared`. Actor-backed SWR caches, **not** reset. A stale cached feed corrupts `CatalogViewModelStateMachineTests`. **Caveat:** `clear()` is `async`; a semaphore-blocking resetter violates the registry's "<10ms, non-blocking" contract — needs a synchronous `_resetForTesting()` (actor `assumeIsolated` clear of `memoryCache`/`accessOrder`). NOT yet done.
4. **`TPPBookRegistry.shared`** residual per-account state — `AppContainer._resetForTesting` does NOT call `registry.reset(...)`. Most download tests inject `TPPBookRegistryMock` (good), but integration tests (`BorrowAndDownloadIntegrationTests`) may use the live one. NOT yet done.
5. **`AccountsManager` background `loadCatalogs` / `group.wait` pumps** — largely mitigated (defer flag + global drain + crawler cancellation, all this branch).

**Verified NOT hazards:** `.suspend()`/`isSuspended` grep across `Palace/` returned only `ImageCache` (already reset). Other `URLSessionTask.suspend` sites are per-instance (rebuilt each test via the AppContainer graph). `DispatchSemaphore` sites are function-local with timeouts.

---

## Strategies tried and why each did NOT converge

1. **Targeted late-write fixes** (AccountsManager `_explicitCancelCalled` guards on `fetchAuthDocumentWithStateMachine` + fallback completion handlers). Correct; closed the AccountStateStore late-write path. Aggregate unchanged.
2. **Global weak-registry drain-all** (`AccountsManager._drainAllLiveInstancesForTesting()` at the test boundary, before the store reset). Correct; drains foreign untorn-down managers. Aggregate unchanged.
3. **Crawler cancellation-responsiveness** (`LibraryRegistryCrawler` `try Task.checkCancellation()`). **Provably eliminated** the `[WS0-DRAIN] cancelAndDrainBackgroundWork TIMED OUT after 3010ms … crawl did not observe cancellation` breadcrumbs (2 → 0). Aggregate unchanged (count went 8 → 12).
4. **Reset-registration** (MockBackend + Chaos). The #1119-aligned approach. Round-6 CI count went **up** to 13 and the run crashed; my hermeticity probe test (`MockBackendResetHermeticityTests`, which drove `invokeAll()` in a test body) itself became a full-suite victim and was removed.

**Conclusion:** individual mechanism fixes are all correct and individually verifiable (WS0-DRAIN gone; deterministic probes passed locally), but they do not move the aggregate — strong evidence the pollution is a **broad pool**, not a small source set, and that the **serial single-process execution model** is the amplifier.

---

## Recommended approach for a fresh investigation

Ranked:

1. **Test-execution isolation (most likely to actually converge).** CI runs serial (`-parallel-testing-enabled NO`, `scripts/xcode-test-optimized.sh:82`) — all ~7k tests in ONE process/pool/singleton-set, so an early polluter bleeds into a victim thousands of tests later. The *local* path already uses `-parallel-testing-enabled YES -maximum-parallel-testing-workers 4`. Options: (a) enable Xcode parallel testing in CI (sim clones = separate processes → global state per-clone; assess macos-15 runner capacity + whether #1119's team disabled it for a reason — they chose serial+reset-based hermeticity in the same PR that added the gate); (b) **shard** the suite into N `xcodebuild test` invocations (`-only-testing` splits by directory/target), each a fresh process, then merge xcresults. Attacks the whole class at once. Verify by whether the shifting-victim reds stop.
2. **Systematic hermeticity audit + a "between-tests" instrumentation that actually works.** The dirty-store namer failed because a legit sync populate is indistinguishable from an async leak at tearDown (the resetter runs after tearDown), and async late-writes fire at an unpredictable later test. A better instrument: a **process-wide `_betweenTests` flag** (set in `testCaseDidFinish`, cleared in `testCaseWillStart` via the observer) + log any global-resource mutation that fires while the flag is set — this names the async leak at fire-time. Then enumerate + register resets for hazards #3/#4 above and any newly-named globals.
3. **Only if 1–2 don't converge:** treat it as a chronically-flaky pool — characterize it (run the suite N times, enumerate the full flaky set), quarantine with a documented tracked allowlist, and enforce the gate on everything else.

**Reproduction / iteration reality:** each hypothesis costs a ~20–35 min full-suite CI run (it does NOT reproduce in local subsets — every subset of the victims passes in isolation; it only manifests under full ~7k-test CI load). Budget for that. Watch `gh pr checks 1232`; pull the failing set + WS0 breadcrumbs from the run log (see "How to read a run" below).

---

## Kept fixes (all SoD-approved, on this branch — do NOT revert)

- `Palace/Accounts/Library/AccountsManager.swift`: `_explicitCancelCalled` write-suppression guards (entry+completion of `fetchAuthDocumentWithStateMachine`, `fallbackFetchFromNetwork`, `fallbackDirectRefresh`); global weak-registry `_drainAllLiveInstancesForTesting()`; boundary drain wiring. All `#if DEBUG` → RELEASE byte-identical.
- `Palace/Accounts/Library/LibraryRegistryCrawler.swift`: 5 `try Task.checkCancellation()` (production, behavior-preserving — cancellation is only issued from test-only paths).
- `PalaceTests/PalaceTestSetup.swift`: `MockBackendURLProtocol._resetForTesting` + `ChaosURLProtocol.reset` registrations.
- CI green-board enforcement patch: **reverted** to defer, preserved in commit `041ef99b0`.

---

## Key references

- CI script: `scripts/xcode-test-optimized.sh` (serial flag :82; exit-code masking :100-103).
- Workflow: `.github/workflows/unit-testing.yml` (test step id `tests` :96; masking `continue-on-error` :104; gate `Fail if tests failed` :880).
- Reset registry: `PalaceTests/PalaceTestSetup.swift` (`registerBuiltInResetters` ~:117), `PalaceSingletonResetObserver.testCaseDidFinish`.
- Quiescence tooling: `PalaceTests/Support/RuntimeQuiescenceAuditor.swift` (`poolResponsivenessViolations` probe — warn-only breadcrumb, not a hard gate), `PalaceTests/Support/PalaceTestCase.swift` (`assertRuntimeQuiescent` ~:57).
- Root-class PR: #1119 (`git show 48211dc8d`).

## How to read a run

```bash
gh pr checks 1232                       # find build-and-test run id
RUN=<id>; JOB=$(gh run view $RUN --json jobs --jq '.jobs[]|select(.name|test("build-and-test";"i")).databaseId'|head -1)
# distinct failing tests:
gh run view $RUN --job "$JOB" --log | grep -E "Parse Test Results.*✗" | sed -E 's/.*✗ //' | sort -u
# the drain-timeout / pool breadcrumbs:
gh run view $RUN --job "$JOB" --log | grep -iE "WS0-DRAIN|WS0-POOL-DIAG"
```
