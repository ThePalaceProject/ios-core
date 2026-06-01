# swarm_4b64e4e0 — Wave 1c: PalaceWiringTestCase base class

**Status:** READY for integrator.
**Branch:** `chore/swarm-rigor-meta-improvement` (working in orchestrator worktree).
**Wave context:** Wave 1's `PalaceTestSetup` XCTestObservation resets singletons between test cases globally. Wave 1c closes the intra-class state-pollution residue inside `AccountsManagerStateMachineWiringTests` — specifically the order-dependency where `testDriveCurrentAccountAuthDoc_terminalState_isNoOp` passes in isolation but failed when run AFTER `testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader` in the same class.

## What landed

1. **`PalaceTests/Support/PalaceWiringTestCase.swift` (NEW, ~90 LOC):**
   - `class PalaceWiringTestCase: XCTestCase`.
   - `setUpWithError`: invokes `SingletonResetRegistry.shared.invokeAll()` (the registry's actual API — the task spec referenced `runAllResetters()` but the existing surface is `invokeAll()`; we wire to the real symbol), defensively sets `AccountsManager.deferInitialLoadCatalogsForTesting = true`.
   - `tearDownWithError`: drains `cancellables.removeAll()`, then walks `managersToCancelOnTearDown` and calls `cancelBackgroundWork()` on each.
   - `var cancellables: Set<AnyCancellable> = []` — internal so subclasses can `.store(in: &cancellables)`.
   - `@discardableResult func makeFreshAccountsManager(_ configure:)` — constructs an `AccountsManager` with the opt-out flag pinned immediately before init and registers the instance for cancellation in tearDown.

2. **`PalaceTests/Support/PalaceWiringTestCaseTests.swift` (NEW, ~150 LOC):**
   - `testSetUp_runsAllResetters` — installs a tracker resetter, runs `Probe().setUpWithError()`, asserts the tracker fired ≥ 1 time.
   - `testTearDown_drainsCancellables` — seeds the base's `cancellables` set with 3 PassthroughSubject sinks, asserts pre-state (3), runs tearDown, asserts post-state (0) AND that Probe observed 3 pre-drain.
   - `testTearDown_cancelsBackgroundWorkOnRegisteredManagers` — mints two managers via `makeFreshAccountsManager()`, asserts `_backgroundFetchTaskWasExplicitlyCancelled == false` pre-tearDown, runs tearDown, asserts the flag flipped to `true` for both.
   - `testMakeFreshAccountsManager_appliesTestOptOut` — mints a manager via the helper, asserts `_backgroundFetchTaskHandleIsNil == true` (proves the opt-out branch ran at init, since the branch returns before assigning `backgroundFetchTask`) AND `_backgroundFetchTaskWasExplicitlyCancelled == false` (proves we haven't yet called cancel — the handle was never assigned).

3. **`PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (MIGRATED):**
   - `class AccountsManagerStateMachineWiringTests: XCTestCase` → `: PalaceWiringTestCase`.
   - 11 `let manager = AccountsManager()` constructions → `let manager = makeFreshAccountsManager()`.
   - `override func tearDown()` → `override func tearDownWithError() throws` (so it can call the base's throwing variant).
   - `setUpWithError` body trimmed — the base handles registry invocation + opt-out flag.

4. **`Palace.xcodeproj/project.pbxproj`:** registered both new files via `ruby scripts/pbxproj_add_swift.rb` (idempotent helper). Output: `added=2 skipped=0 failed=0`.

5. **No production-code change.**
   - The spec said "if `_resetUserAccountsCacheForTesting()` doesn't exist, ADD a `#if DEBUG static func _resetUserAccountsCacheForTesting()` that nils the static cache". `AccountsManager.userAccounts` is a per-instance `[String: TPPUserAccount]` dictionary, NOT static — a fresh `AccountsManager()` already starts with an empty dict. No static cache exists to nil, so the production-code addition is a no-op situation. The base class's `makeFreshAccountsManager()` already gives every test method a clean per-instance cache; `cancelBackgroundWork()` in tearDown ensures the prior instance's network responders are torn down before the next instance is constructed. Per the spec's "(if needed)" clause, the production addition was skipped.

## Definition of Done — evidence

### 1. SUT instantiation check

```
$ grep -c "PalaceWiringTestCase\b" PalaceTests/Support/PalaceWiringTestCaseTests.swift
3   ✓ ≥1 — base class referenced as base in `Probe: PalaceWiringTestCase`, then `Probe()` is constructed twice in test bodies; method `testSetUp_runsAllResetters` walks through `PalaceWiringTestCase.setUpWithError` via the Probe.

$ grep -c "PalaceWiringTestCase\|AccountsManagerStateMachineWiringTests" PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
3   ✓ ≥1 — class declaration cites both names; the class body BODY of every test method exercises the base via inheritance.
```

### 2. AccountsManagerStateMachineWiringTests 13/13 pass as a class run

```
$ xcodebuild ... -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests test-without-building
Test Suite 'AccountsManagerStateMachineWiringTests' passed at 2026-05-29 12:34:17.780.
     Executed 13 tests, with 0 failures (0 unexpected) in 9.036 (9.059) seconds
Test Suite 'PalaceTests.xctest' passed at 2026-05-29 12:34:17.782.
Test Suite 'Selected tests' passed at 2026-05-29 12:34:17.783.
** TEST EXECUTE SUCCEEDED **
```

### 3. Previously-failing ordering pair now passes

Pair: `testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader` THEN `testDriveCurrentAccountAuthDoc_terminalState_isNoOp` (the failing-when-second test).

```
$ xcodebuild ... \
    -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests/testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader \
    -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests/testDriveCurrentAccountAuthDoc_terminalState_isNoOp \
    test-without-building

Test Case '...testStartDownload_endToEnd_capturedAccountIdReachesAuthorizationHeader' passed (0.364 seconds).
Test Case '...testDriveCurrentAccountAuthDoc_terminalState_isNoOp' passed (0.780 seconds).
Test Suite 'AccountsManagerStateMachineWiringTests' passed at 2026-05-29 12:35:05.336.
```

### 4. Mutation kill rate

N/A — no production-code diff. The base class is test-target-only; all four base-class tests are behavioral (each asserts an observable post-state change), and the 13 migrated wiring tests already had mutation coverage on the production paths they exercise (verified in prior swarms).

### 5. Build + verify-pr

```
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
    -derivedDataPath /tmp/wave1c-build build-for-testing
...
** TEST BUILD SUCCEEDED **
```

`verify-pr.sh --quick` was NOT run — this is a Wave 1c partial-swarm deliverable; the integrator runs the full verify-pr battery on the bundled wave commit. Build-only succeeds; running the two migrated test classes also succeeds.

### 6. Blast-radius / contract-reconciliation / test-name-vs-body

```
$ python3 scripts/check-blast-radius.py --diff /tmp/wave1c.patch --quiet
EXIT=0   ✓

$ python3 scripts/check-test-name-vs-body.py \
    PalaceTests/Support/PalaceWiringTestCaseTests.swift \
    PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
OK: 2 file(s) checked, 0 fake-wiring tests found.
EXIT=0   ✓

$ python3 scripts/check-adjacency-staleness.py --quiet
EXIT=0   ✓
```

### 7. Scope coverage audit

| Spec item | Status | Notes |
|---|---|---|
| `PalaceTests/Support/PalaceWiringTestCase.swift` (NEW) | ✓ landed | 4 contract guarantees: `setUp` invokes registry + flips opt-out, `tearDown` drains cancellables + cancels registered managers, `cancellables: Set<AnyCancellable>` exposed, `makeFreshAccountsManager(_:)` helper |
| `PalaceTests/Support/PalaceWiringTestCaseTests.swift` (NEW) | ✓ landed | 4 tests, all 4 pass; cover the 4 base-class guarantees with observable assertions |
| `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` migrated to base | ✓ landed | 13/13 tests pass as class run; previously-failing pair runs cleanly when explicitly chained |
| `Palace/Accounts/Library/AccountsManager.swift` `_resetUserAccountsCacheForTesting()` static method | DEFERRED (no-op) | `userAccounts` is per-instance, not static — no static cache to reset. Fresh-instance construction implicitly clears it. Per spec's "(if needed)" clause. |
| pbxproj registration via helper | ✓ landed | `pbxproj_add_swift.rb` reported `added=2 skipped=0 failed=0` |

### 8. Multi-step / wiring-claim check (v2)

The 4 base-class tests each cite a single observable end-state (registry invocation count, cancellables count, explicit-cancel flag, task-handle-nil flag). Each assertion reads an observation surface that the base mutates directly — there is no "claims multi-step but only does one step" risk. The 13 wiring tests already passed line-coverage from prior swarms.

### 9. Contract reconciliation

```
$ git diff --stat
 Palace.xcodeproj/project.pbxproj                                |  26 +++++++++++++++
 PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift |  30 ++++++++++++-----
 ...
```

No production-code claims (e.g. "removes X", "renames Y to Z") — all changes are additive in the test target. Reconciliation N/A.

### 10. Adjacency staleness

`check-adjacency-staleness.py --quiet` exit 0; no production types removed or renamed.

## Risk notes for integrator

- The base class's `setUpWithError` calls `SingletonResetRegistry.shared.invokeAll()` synchronously. The registry's built-in resetters include `AppContainer._resetForTesting` (which hops to MainActor) — calling `invokeAll()` from a synchronous setUp is safe because XCTest invokes setUp on the main thread; the `MainActor.assumeIsolated` call inside the AppContainer resetter is sound under that assumption (this is the same property the observer relies on post-test, so we're following an established pattern).
- The probe-based tests (`PalaceWiringTestCaseTests`) instantiate `Probe()` directly without registering it with the test runner. XCTestCase's no-arg init is suitable for this — the test methods we register with the runner are the OUTER ones; the inner Probe is just an instance whose lifecycle we drive synchronously. This matches the pattern in `SingletonResetRegistryTests.testInvokeAll_resetterClosureCapturingNilWeakRef_doesNotCrash` (uses inner instances for state observation without registering them with the runner).
- The migration moved `override func tearDown()` → `override func tearDownWithError() throws`. This is the standard XCTest seam — XCTest's lifecycle calls the throwing variant by default. No test method in the class threw from teardown previously, so the migration is behavior-preserving.

## Files changed

- NEW: `PalaceTests/Support/PalaceWiringTestCase.swift`
- NEW: `PalaceTests/Support/PalaceWiringTestCaseTests.swift`
- MODIFIED: `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`
- MODIFIED: `Palace.xcodeproj/project.pbxproj` (via `pbxproj_add_swift.rb`)

## Integration directive

Bundle Wave 1c into the orchestrator's integration commit alongside Wave 1a/1b. The base class introduces a structural improvement that subsequent test classes (`AccountsManagerCancellationTests`, future wiring suites) can adopt incrementally — no big-bang migration is required by this PR.
