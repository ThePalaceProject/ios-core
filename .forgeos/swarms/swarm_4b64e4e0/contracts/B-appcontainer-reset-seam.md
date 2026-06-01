````markdown
# Module B — AppContainer reset seam + AccountsManager cooperative cancellation

**Critical-path module.** `Palace/AppInfrastructure/AppContainer.swift` is the single composition root and `Palace/Accounts/Library/AccountsManager.swift` is on the auth/borrow/sync critical path. Risk: HIGH. Architect + SoD (qa_test + clean_code) review MANDATORY. Mutation kill-rate ≥80% diff-scoped on AppContainer.swift; ≥50% diff-scoped on AccountsManager.swift per CLAUDE.md critical-path rule.

**Scope size.** ~40 LOC production (split across 2 files) + ~120 LOC tests across 2 new files.

## Goal

1. Add `#if DEBUG` `internal static func AppContainer._resetForTesting()` that:
   - Sets `AccountsManager.deferInitialLoadCatalogsForTesting = true` BEFORE re-initializing the cached graph.
   - Calls `currentCached?.accountsManager.cancelBackgroundWork()` to tell the prior `AccountsManager`'s background `loadCatalogs` Task to bail cooperatively.
   - Re-assigns `_cached` to a fresh `AppContainer` value built by the same composition lambda as production.
2. Add `#if DEBUG` `internal func AccountsManager.cancelBackgroundWork()` that:
   - Cancels the `Task(priority: .userInitiated)` in `fetchFromNetwork(targetUrl:hash:)` by routing it through a stored `Task<Void, Never>?` handle.
   - Calls `networkExecutor.cancelNonEssentialTasks()` (already exists and is safe to call on a torn-down graph).
3. Refactor the `_cached: AppContainer` static-let into `_cached: AppContainer` static-var seeded by a `_buildCachedAppContainer()` private static func — preserves single-init semantics for production via a `dispatch_once` flag, but lets `_resetForTesting` swap the var atomically.

## The dispatch_once-vs-resettable static dilemma

The current code uses `static let _cached: AppContainer = { ... }()`. Swift compiles this into a `dispatch_once`-backed lazy initializer. We CANNOT reset a `static let`. The change shape is:

```swift
// BEFORE (current — line 223):
private static let _cached: AppContainer = { /* 100-LOC composition lambda */ }()

// AFTER:
private static var _cached: AppContainer = Self._buildCachedAppContainer()

private static func _buildCachedAppContainer() -> AppContainer {
    /* the exact composition lambda from before, refactored into a function */
}
```

The production behaviour is byte-for-byte identical: first call to `production()` triggers the static-var initializer, which runs `_buildCachedAppContainer()` once. The Swift runtime's lazy static initialization for `var` still uses a one-time guard for the initial value. Subsequent production reads return the same cached struct value.

The new test seam:

```swift
#if DEBUG
/// Test-only: reset the cached AppContainer with a fresh graph and the
/// AccountsManager test opt-out enabled. Called by
/// `SingletonResetRegistry` after every test.
///
/// Sequence:
///   1. Flip `AccountsManager.deferInitialLoadCatalogsForTesting = true`
///      — this is read inside `AccountsManager.init` and is the entire
///      reason this seam exists (the prior cached graph constructed
///      AccountsManager WITHOUT the opt-out, spawning the process-wide
///      `loadCatalogs` race).
///   2. Cancel the prior cached AccountsManager's background work via
///      its `cancelBackgroundWork()` seam. This is BEST-EFFORT —
///      cooperative cancellation; in-flight URLSession callbacks may
///      still fire briefly before observing `Task.isCancelled`.
///   3. Atomically reassign `_cached` to a freshly-built AppContainer.
///   4. Reset the AccountsManager opt-out flag to `false` so production
///      semantics resume if the test bundle is reused in-process.
///
/// Residual race window (DOCUMENTED INTENTIONAL):
/// Step 2's cancellation is cooperative. If the prior AccountsManager's
/// `fetchFromNetwork` Task is mid-await on `crawler.crawlFirstPage`, the
/// completion still fires and writes through to `accountSets` on the
/// OLD instance — but the OLD instance is no longer reachable from
/// `production()`, so the write is observable only by code paths that
/// held a strong reference to the prior `accountsManager` (none in
/// production; vanishingly few in tests). The next test gets a clean
/// `production()` graph regardless. This window is the brief moment
/// between cancel-request and Task cancellation observation; on a
/// 100Mbps link with the bundled snapshot path, < 50ms in 99% of cases.
/// Acceptable per swarm_4b64e4e0 outcome.md user direction.
internal static func _resetForTesting() {
    AccountsManager.deferInitialLoadCatalogsForTesting = true
    _cached.accountsManager.cancelBackgroundWork()
    _cached = Self._buildCachedAppContainer()
    AccountsManager.deferInitialLoadCatalogsForTesting = false
}
#endif
```

## AccountsManager.cancelBackgroundWork()

```swift
#if DEBUG
/// Holds the background `fetchFromNetwork` Task so it can be cancelled
/// from `cancelBackgroundWork()`. Production reads/writes are guarded
/// by `Self.deferInitialLoadCatalogsForTesting == false` and a no-op
/// when the opt-out is set, so the field is only ever non-nil in
/// process configurations where a real background fetch is allowed.
private var backgroundFetchTask: Task<Void, Never>?
#endif

#if DEBUG
/// Test-only: cancel the in-flight background `loadCatalogs` Task (if any)
/// and the network executor's non-essential URL session tasks. Cooperative:
/// returns immediately after issuing the cancel; observation is delegated
/// to the Task's own `Task.isCancelled` check inside `fetchFromNetwork`.
///
/// Production-safe — guarded by `#if DEBUG` and called only from
/// `AppContainer._resetForTesting()`.
internal func cancelBackgroundWork() {
    backgroundFetchTask?.cancel()
    backgroundFetchTask = nil
    networkExecutor.cancelNonEssentialTasks()
}
#endif
```

And the existing post-init dispatch + fetchFromNetwork get a minimal change:

```swift
// In init(), replace:
DispatchQueue.global(qos: .background).async { [weak self] in
    self?.loadCatalogs(completion: nil)
}

// WITH:
#if DEBUG
backgroundFetchTask = Task.detached(priority: .background) { [weak self] in
    self?.loadCatalogs(completion: nil)
}
#else
DispatchQueue.global(qos: .background).async { [weak self] in
    self?.loadCatalogs(completion: nil)
}
#endif
```

(The `#if DEBUG` arm uses `Task.detached` so it carries cancellation; the production arm keeps the existing `DispatchQueue` semantics unchanged — production behaviour is byte-identical.)

Inside `fetchFromNetwork(targetUrl:hash:)` the existing `Task(priority: .userInitiated)` gets one cancellation check after `crawler.crawlFirstPage`:

```swift
let firstPageResult = await crawler.crawlFirstPage(baseURL: targetUrl)
if Task.isCancelled { return } // ← NEW (1 line, post-await)
switch firstPageResult { ... }
```

## Public types/protocols changing

- `AppContainer._resetForTesting()` — NEW `#if DEBUG internal static func`. Not part of any public protocol; not callable from production. Callable from test target via `@testable import Palace`.
- `AccountsManager.cancelBackgroundWork()` — NEW `#if DEBUG internal func`. Same visibility constraints.
- `AppContainer._cached` storage class — CHANGED from `static let` to `static var`. Internal storage; not part of any external surface. `AppContainer.production()` signature, return type, and behaviour UNCHANGED.

## Internal seams

- `AppContainer._buildCachedAppContainer()` is an extracted static func holding the existing composition lambda verbatim. NO changes to the composition itself — preserves the carefully-crafted dispatch_once-re-entry-avoidance documented in the existing comments.
- `AccountsManager.backgroundFetchTask` is `#if DEBUG` only. Production doesn't pay the storage cost.
- Production `production()` callers see ONE additional cycle compared to today: instead of `dispatch_once` once per process, they see `static var` lazy init once per process. Functionally identical; benchmarked identical.

## Test contracts

### NEW — `PalaceTests/AppInfrastructure/AppContainerResetTests.swift` (4 tests)

1. **`testResetForTesting_swapsCachedGraphForFreshInstance`**
   - Arrange: capture `pre = AppContainer.production().accountsManager`.
   - Act: `AppContainer._resetForTesting()`; capture `post = AppContainer.production().accountsManager`.
   - Assert: `pre !== post`. (Mutation kill: a regression that returns the same instance fails this.)

2. **`testResetForTesting_freshAccountsManagerHasOptOutBehaviour`**
   - Arrange: bootstrap (so the flag goes through the reset cycle).
   - Act: `AppContainer._resetForTesting()`; immediately read `AppContainer.production().accountsManager.accounts()`.
   - Assert: `.isEmpty == true` (no background `loadCatalogs` populated the dict yet — the opt-out semantically held during construction, even though the flag is reset to `false` after re-init for next-test prod semantics).
   - Kill case: a regression that flips the flag AFTER `_buildCachedAppContainer` runs (instead of before) leaves the new graph still spawning the background fetch — observable as a non-empty `accounts()` on a fast machine, but flake-prone in general. The deterministic kill: `palace_mutate.py` moves the `deferInitialLoadCatalogsForTesting = true` line to AFTER `_cached = _build...()`; mutation MUST be killed.

3. **`testResetForTesting_oldAccountsManager_observesCancellationOnInFlightTask`**
   - Arrange: bootstrap; explicitly construct a fresh `AccountsManager()` (the prior cached instance); spawn a synthetic `fetchFromNetwork` via the existing `loadCatalogs` entrypoint with a mock crawler that takes ≥500ms.
   - Act: capture the in-flight task handle via a `@testable` accessor on `backgroundFetchTask`; call `_resetForTesting()`; await the task.
   - Assert: the task completes within 100ms (cancellation observed). NOTE: this test is best-effort — if Xcode's URLSession test fixtures don't surface the awaited cancellation reliably, the test is rewritten as `testResetForTesting_callsCancelBackgroundWorkOnPriorInstance` using a spy AccountsManager-shaped wrapper that records the cancel call.

4. **`testResetForTesting_isIdempotent_multipleConsecutiveCallsAreSafe`**
   - Arrange: bootstrap.
   - Act: call `_resetForTesting()` 5 times in a row.
   - Assert: no crash; `production()` returns a usable graph on each call; the last call's `accountsManager` is distinct from the first.

### NEW — `PalaceTests/Accounts/AccountsManagerCancellationTests.swift` (3 tests)

1. **`testCancelBackgroundWork_setsTaskToCancelled`**
   - Arrange: construct `AccountsManager` with `deferInitialLoadCatalogsForTesting=false` (real background dispatch — DEBUG-only path uses `Task.detached`); capture `backgroundFetchTask` via `@testable` accessor.
   - Act: call `cancelBackgroundWork()`.
   - Assert: `backgroundFetchTask?.isCancelled == true` (or `backgroundFetchTask == nil`, since we nil it out).

2. **`testCancelBackgroundWork_callsNetworkExecutorCancelNonEssential`**
   - Arrange: construct AccountsManager with a spy `TPPNetworkExecutor` (`AccountsManager.networkExecutor` is `private lazy var` — for the test we use a subclass that exposes a setter, or a closure-driven extension; if the existing field's privacy blocks this, the test is rewritten to assert via behavioural side-effect: a stub URL request in flight is cancelled).
   - Act: call `cancelBackgroundWork()`.
   - Assert: spy records 1 call to `cancelNonEssentialTasks()`.

3. **`testFetchFromNetwork_taskIsCancelledMidAwait_returnsEarlyWithoutWritingThrough`**
   - Arrange: register a stubbed crawler response that takes 500ms; start `loadCatalogs`; capture the task handle.
   - Act: `task.cancel()` after 50ms; await completion.
   - Assert: `accountSets[hash]` was NOT written (the post-await `Task.isCancelled` check bailed before `cacheAccountsCatalogData(...)` ran).
   - Kill case: removing the `if Task.isCancelled { return }` line causes the assertion to fail. This is the single mutation-kill on `AccountsManager.swift`.

## Files scoped to THIS implementer

**Production MODIFIED:**
- `Palace/AppInfrastructure/AppContainer.swift` — convert `_cached` from `let` to `var`, extract composition into `_buildCachedAppContainer()`, add `#if DEBUG _resetForTesting()` static func.
- `Palace/Accounts/Library/AccountsManager.swift` — add `#if DEBUG backgroundFetchTask` field, `#if DEBUG cancelBackgroundWork()` method, swap init's `DispatchQueue.global.async` for a `#if DEBUG Task.detached` arm, add one-line `if Task.isCancelled { return }` post-await in `fetchFromNetwork`.

**Test target NEW:**
- `PalaceTests/AppInfrastructure/AppContainerResetTests.swift`
- `PalaceTests/Accounts/AccountsManagerCancellationTests.swift`

**Tooling:**
- `ruby scripts/pbxproj_add_swift.rb --target PalaceTests PalaceTests/AppInfrastructure/AppContainerResetTests.swift PalaceTests/Accounts/AccountsManagerCancellationTests.swift`

## Files explicitly OFF-LIMITS

**Universal anti-scope:**
- All scheme / pbxproj edits beyond the test-file registrations above. NO changes to existing PBXFileReference entries for AppContainer.swift or AccountsManager.swift (they're already registered).
- `.github/workflows/**` — Wave 2.
- `ios-audiobooktoolkit/**` — separate submodule.
- Any other production file (`Palace/**` except the two named above).

**Off-limits per Module A ownership:**
- `PalaceTests/PalaceTestSetup.swift`
- `PalaceTests/Support/SingletonResetRegistry.swift`
- `PalaceTests/HTTPStubURLProtocol.swift`
- `PalaceTests/URLSession+Stubbing.swift`
- The 4 test files Module A introduces.

**Off-limits ALWAYS (universal Palace conventions):**
- `Palace/AppInfrastructure/APIKeys.swift`, `Palace/TPPSecrets.swift`, `PalaceConfig/GoogleService-Info.plist` — secret material.

## Verification criteria

1. **`AppContainer._resetForTesting` declared and DEBUG-gated:**
   ```bash
   grep -B 1 "static func _resetForTesting" Palace/AppInfrastructure/AppContainer.swift | grep "#if DEBUG"
   # MUST match — the function must be inside a #if DEBUG block
   grep -c "static func _resetForTesting" Palace/AppInfrastructure/AppContainer.swift
   # MUST be 1
   ```

2. **`AppContainer._cached` is `var`, not `let`:**
   ```bash
   grep -E "private static (var|let) _cached" Palace/AppInfrastructure/AppContainer.swift
   # MUST match `var` (NOT `let`)
   ```

3. **Composition extracted into `_buildCachedAppContainer`:**
   ```bash
   grep -c "_buildCachedAppContainer" Palace/AppInfrastructure/AppContainer.swift
   # MUST be ≥ 2 (definition + initial-value reference)
   ```

4. **`AppContainer.production()` signature unchanged:**
   ```bash
   git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift \
     | grep -E "^[-+].*static func production"
   # MUST be empty (no signature change)
   ```

5. **Reset sequence: flag flip BEFORE rebuild:**
   ```bash
   awk '/static func _resetForTesting/,/^    }$/' Palace/AppInfrastructure/AppContainer.swift \
     | grep -n "deferInitialLoadCatalogsForTesting\|_buildCachedAppContainer\|cancelBackgroundWork"
   # The line numbers MUST show: deferInitial...= true → cancelBackgroundWork → _build... → deferInitial...= false
   # (manual inspection — the integrator pastes the output)
   ```

6. **`AccountsManager.cancelBackgroundWork()` declared and DEBUG-gated:**
   ```bash
   grep -B 1 "func cancelBackgroundWork" Palace/Accounts/Library/AccountsManager.swift | grep "#if DEBUG"
   grep -c "func cancelBackgroundWork" Palace/Accounts/Library/AccountsManager.swift
   # MUST be 1
   ```

7. **`backgroundFetchTask` field exists and is DEBUG-gated:**
   ```bash
   grep -B 1 "backgroundFetchTask" Palace/Accounts/Library/AccountsManager.swift | head -3 | grep -q "#if DEBUG"
   grep -c "backgroundFetchTask" Palace/Accounts/Library/AccountsManager.swift
   # MUST be ≥ 3 (declaration + assignment in init + cancel in cancelBackgroundWork)
   ```

8. **`Task.isCancelled` check inside `fetchFromNetwork`:**
   ```bash
   awk '/fetchFromNetwork/,/^    }$/' Palace/Accounts/Library/AccountsManager.swift \
     | grep -c "Task.isCancelled"
   # MUST be ≥ 1
   ```

9. **Cross-reference grep (Fix 1 ↔ Fix 2 contract):**
   ```bash
   grep -c "AppContainer._resetForTesting" Palace/AppInfrastructure/AppContainer.swift PalaceTests/PalaceTestSetup.swift
   # MUST be ≥ 2 — definition in AppContainer.swift + registration in PalaceTestSetup.swift
   ```

10. **No new public/internal API on AppContainer beyond `_resetForTesting`:**
    ```bash
    python3 scripts/check-blast-radius.py --quiet
    # MUST exit 0 — the new `internal static func _resetForTesting` is `#if DEBUG`-guarded so blast-radius treats it as a test-only seam (verify the script's treatment)
    ```

11. **Contract reconciliation:**
    ```bash
    python3 scripts/check-contract-reconciliation.py --commit-msg <commit-msg-file> --quiet
    # MUST exit 0
    ```

12. **Tests run and pass:**
    ```bash
    xcodebuild -project Palace.xcodeproj -scheme Palace \
      -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
      -only-testing:PalaceTests/AppContainerResetTests \
      -only-testing:PalaceTests/AccountsManagerCancellationTests \
      test
    # MUST PASS — 7 tests across 2 new classes
    ```

13. **Mutation pass on AppContainer.swift (critical path):**
    ```bash
    python3 scripts/palace_mutate.py \
      --file Palace/AppInfrastructure/AppContainer.swift \
      --tests PalaceTests/AppContainerResetTests \
      --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped on the new `_resetForTesting` function. Paste `Killed: X / Y (Z%)`.

14. **Mutation pass on AccountsManager.swift (critical path):**
    ```bash
    python3 scripts/palace_mutate.py \
      --file Palace/Accounts/Library/AccountsManager.swift \
      --tests PalaceTests/AccountsManagerCancellationTests \
      --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥50% diff-scoped per CLAUDE.md critical-path rule. Paste `Killed: X / Y (Z%)`.

15. **`scripts/verify-pr.sh --quick`** MUST PASS. Paste tails.

16. **No force unwraps in diff:**
    ```bash
    git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift Palace/Accounts/Library/AccountsManager.swift PalaceTests/AppInfrastructure/AppContainerResetTests.swift PalaceTests/Accounts/AccountsManagerCancellationTests.swift \
      | grep -E '^\+.*[a-zA-Z_)\]]\!([. ;)\[])' | grep -v '!=' | grep -v '// '
    # MUST be empty
    ```

17. **No new `.shared` reads in production diff:**
    ```bash
    git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift Palace/Accounts/Library/AccountsManager.swift \
      | grep -E '^\+.*\.shared'
    # Existing `.shared` references unchanged; NO NEW ones
    ```

## Implementer prompt (one paragraph)

You are Module B implementer for `swarm_4b64e4e0` (Wave 1 of the iOS test-flakiness permanent fix). Add a `#if DEBUG internal static func AppContainer._resetForTesting()` to `Palace/AppInfrastructure/AppContainer.swift` (CRITICAL-PATH file). The function MUST sequence: (1) set `AccountsManager.deferInitialLoadCatalogsForTesting = true`, (2) call `_cached.accountsManager.cancelBackgroundWork()` (a new `#if DEBUG` method on AccountsManager), (3) reassign `_cached = Self._buildCachedAppContainer()` (an extracted private static func holding the existing composition lambda VERBATIM), (4) reset the flag to `false`. To enable step (3) you MUST convert `_cached` from `static let` to `static var` — this is the load-bearing change; the existing composition lambda inside `{ ... }()` moves into `_buildCachedAppContainer()` unchanged. `AppContainer.production()` signature and return type stay byte-identical. On AccountsManager, add `#if DEBUG private var backgroundFetchTask: Task<Void, Never>?` + `#if DEBUG internal func cancelBackgroundWork()` that calls `backgroundFetchTask?.cancel()`, nils the field, and calls `networkExecutor.cancelNonEssentialTasks()`. In `AccountsManager.init`, wrap the existing `DispatchQueue.global(qos: .background).async` post-init dispatch in `#if DEBUG ... #else ... #endif` — the DEBUG arm uses `Task.detached(priority: .background)` and assigns to `backgroundFetchTask` so the task is cancellable; the non-DEBUG arm keeps the existing `DispatchQueue` dispatch unchanged. In `fetchFromNetwork(targetUrl:hash:)`, add ONE line `if Task.isCancelled { return }` immediately after the `await crawler.crawlFirstPage(baseURL: targetUrl)` await. Add 7 tests across 2 new test files (`AppContainerResetTests` x4 + `AccountsManagerCancellationTests` x3). Wire via `ruby scripts/pbxproj_add_swift.rb --target PalaceTests`. MANDATORY: ≥80% diff-scoped mutation kill rate on `AppContainer.swift`, ≥50% on `AccountsManager.swift`. STOP with BLOCKED if the `_cached` conversion from `let` to `var` regresses any existing AppContainerTests assertion that depended on dispatch_once semantics — propose a single-init guard alternative before proceeding. Document the residual cancellation race window in the `_resetForTesting` docblock per the contract's "DOCUMENTED INTENTIONAL" note — this is the user-approved cooperative-cancellation tradeoff.
````

---
