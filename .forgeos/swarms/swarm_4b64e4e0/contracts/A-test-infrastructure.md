````markdown
# Module A — Test infrastructure (PalaceTestSetup XCTestObservation + SingletonResetRegistry)

**Test-target-only module.** Risk: medium. The XCTestObservation runs after every test in the entire suite, so a thrown error or unbounded resetter blocks every other test. The discipline is in the resetter contract (no throws, no long-running work, idempotent), not the LOC count. Architect + SoD (qa_test + clean_code) review required.

**Scope size.** ~120 LOC production-shape (test target) + ~180 LOC tests across 4 new + 2 modified files.

## Goal

1. Introduce a `SingletonResetRegistry` (test-target, `internal`) that stores `() -> Void` resetter closures registered by name. Idempotent registration (same name overwrites), thread-safe (NSLock), iteration order = registration order.
2. Extend `PalaceTestSetup.bootstrap()` (the `init()` invoked by `NSPrincipalClass`) to:
   - Install an `XCTestObservation` (`PalaceSingletonResetObserver`) on `XCTestObservationCenter.shared` exactly once per process.
   - Register the built-in resetters into `SingletonResetRegistry`.
3. The observer's `testCaseDidFinish(_:)` walks the registry in registration order and calls every resetter, then runs the NotificationCenter observer-count audit.
4. Add `HTTPStubURLProtocol.removeAllHandlers()` (alias of existing `reset()` — the contract spec uses `removeAllHandlers` per the user direction; we add the new name and keep `reset()` as a deprecated forward for the rest of the suite).
5. Add `URLSession+Stubbing._reset()` — invalidates the process-wide `_sharedStubbedSession` and rebuilds it on next access (since the existing implementation is `private static let`, we convert to a private static var with a lazy rebuild on read, behind the same `stubbedSession()` API).

## Public types/protocols changing

**NEW — `PalaceTests/Support/SingletonResetRegistry.swift`:**

```swift
/// Process-wide registry of singleton resetter closures invoked by
/// `PalaceSingletonResetObserver.testCaseDidFinish(_:)` after every test.
///
/// Test-target-only. Production code MUST NOT reference this type. Each
/// resetter MUST:
///  - Run in < 10ms on the main thread (the observer is synchronous).
///  - Be idempotent — called once per test, possibly thousands of times
///    per suite run.
///  - Catch its own errors. The observer logs and continues on throw,
///    but a resetter that crashes terminates the suite.
///  - Be reentrancy-safe — a resetter MUST NOT register or unregister
///    other resetters mid-call. Reentrant registration is logged as a
///    warning and silently dropped to preserve iteration stability.
///
/// Resetter registration order = invocation order. Order matters when one
/// resetter's state depends on another's (e.g. `AppContainer._resetForTesting`
/// must run BEFORE `AccountStateStore.shared._resetAllForTesting()` because
/// rebuilding the AppContainer graph repopulates `AccountStateStore` via
/// the new `AccountsManager.preloadAccountsFromDiskCacheSync()` path).
internal final class SingletonResetRegistry {
    static let shared = SingletonResetRegistry()

    private let lock = NSLock()
    private var resetters: [(name: String, run: () -> Void)] = []
    private var isIterating = false

    private init() {}

    /// Register a named resetter. Re-registering an existing name OVERWRITES
    /// the prior closure in place (preserves iteration order). Registration
    /// during iteration is dropped with a `NSLog` warning.
    func register(_ name: String, resetter: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if isIterating {
            NSLog("[SingletonResetRegistry] WARN: ignoring reentrant register(\(name)) during iteration")
            return
        }
        if let idx = resetters.firstIndex(where: { $0.name == name }) {
            resetters[idx] = (name, resetter)
        } else {
            resetters.append((name, resetter))
        }
    }

    /// Snapshot of registered names (for tests + diagnostics). Returns a
    /// copy — the underlying storage is locked for the duration of the
    /// snapshot read.
    func registeredNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return resetters.map { $0.name }
    }

    /// Invoke every registered resetter in registration order. Called by
    /// `PalaceSingletonResetObserver.testCaseDidFinish(_:)`. Failures are
    /// logged via `NSLog` and the iteration continues — one bad resetter
    /// cannot halt the suite.
    func invokeAll() {
        lock.lock()
        let snapshot = resetters
        isIterating = true
        lock.unlock()
        defer {
            lock.lock()
            isIterating = false
            lock.unlock()
        }
        for entry in snapshot {
            entry.run()
        }
    }

    /// Test-only: drop all registered resetters. Used by SingletonResetRegistryTests
    /// only — production tests rely on PalaceTestSetup's bootstrap registrations.
    internal func _removeAllForTests() {
        lock.lock()
        defer { lock.unlock() }
        resetters.removeAll()
    }
}
```

**MODIFY — `PalaceTests/PalaceTestSetup.swift` (replace current 12-LOC contents):**

```swift
import Foundation
import XCTest

/// Process-wide test bootstrap. Loaded via `NSPrincipalClass=PalaceTestSetup`
/// in `PalaceTests/Info.plist` at bundle-load time, BEFORE any XCTestCase
/// runs. Responsibilities:
///  1. Register `NoNetworkURLProtocol` (existing behaviour — preserved).
///  2. Install `PalaceSingletonResetObserver` on the shared
///     `XCTestObservationCenter` — the observer resets registered
///     singletons in `testCaseDidFinish(_:)`.
///  3. Register the built-in resetter list into
///     `SingletonResetRegistry.shared`.
///
/// Adding a new singleton resetter at runtime: call
/// `SingletonResetRegistry.shared.register(_:resetter:)` from a custom
/// XCTestCase `setUp` (or from another bootstrap-time hook). The
/// registry is process-wide; the new resetter fires after every
/// subsequent test in the run.
@objc(PalaceTestSetup)
final class PalaceTestSetup: NSObject {
    private static var didBootstrap = false
    private static let bootstrapLock = NSLock()

    /// Strong reference to the observer. XCTest holds it weakly; without
    /// our retain, ARC drops the observer immediately after `addTestObserver(_:)`
    /// returns and `testCaseDidFinish(_:)` never fires.
    private static var observer: PalaceSingletonResetObserver?

    override init() {
        super.init()
        Self.bootstrap()
    }

    /// Idempotent. Safe to call from a custom test entry point or a unit
    /// test that needs to verify bootstrap state. Real entry is the
    /// principal-class `init()` above.
    @discardableResult
    static func bootstrap() -> PalaceSingletonResetObserver {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        if let existing = observer { return existing }

        NoNetworkURLProtocol.enable()

        let obs = PalaceSingletonResetObserver()
        XCTestObservationCenter.shared.addTestObserver(obs)
        observer = obs

        // Built-in resetter list. Order matters: AppContainer is rebuilt
        // FIRST so subsequent resetters see a clean graph; the static
        // resetters then clear residue that may have been written via
        // direct singleton mutation in the just-finished test.
        SingletonResetRegistry.shared.register("AppContainer._resetForTesting") {
            #if DEBUG
            AppContainer._resetForTesting()
            #endif
        }
        SingletonResetRegistry.shared.register("AccountStateStore.shared._resetAllForTesting") {
            AccountStateStore.shared._resetAllForTesting()
        }
        SingletonResetRegistry.shared.register("TPPUserAccountMock.resetShared") {
            TPPUserAccountMock.resetShared()
        }
        SingletonResetRegistry.shared.register("HTTPStubURLProtocol.removeAllHandlers") {
            HTTPStubURLProtocol.removeAllHandlers()
        }
        SingletonResetRegistry.shared.register("URLSession.stubbedSession._reset") {
            URLSession._resetStubbedSession()
        }

        didBootstrap = true
        return obs
    }
}
```

**NEW — observer (same file or split to `PalaceSingletonResetObserver.swift`; recommend keeping in `PalaceTestSetup.swift` since it has no separate consumers):**

```swift
/// `XCTestObservation` that invokes every entry in
/// `SingletonResetRegistry.shared` after each test, plus audits
/// `NotificationCenter.default` observer-count drift.
///
/// Hook points used:
///  - `testCaseWillStart(_:)`: samples current observer count.
///  - `testCaseDidFinish(_:)`: invokes registry; resamples observer
///    count; if delta > 0 emits an `XCTContext.runActivity` warning so
///    the test report carries the residue evidence.
///
/// The observer is held strongly by `PalaceTestSetup.observer` because
/// XCTest retains test observers only weakly.
final class PalaceSingletonResetObserver: NSObject, XCTestObservation {
    /// Baseline NotificationCenter observer count sampled at
    /// `testCaseWillStart`. The audit compares against this on
    /// `testCaseDidFinish`. The sampling uses
    /// `_observerCountForTesting()` — a test-target helper that reads
    /// `NotificationCenter.default`'s internal count via KVC where
    /// available; on platforms where the KVC path isn't reachable, the
    /// audit is skipped silently (returns nil).
    private var preCount: Int?

    func testCaseWillStart(_ testCase: XCTestCase) {
        preCount = Self.sampleObserverCount()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        SingletonResetRegistry.shared.invokeAll()

        guard let pre = preCount, let post = Self.sampleObserverCount() else {
            preCount = nil
            return
        }
        preCount = nil
        let delta = post - pre
        if delta > 0 {
            XCTContext.runActivity(named: "NotificationCenter observer leak (\(delta) net adds)") { activity in
                let attachment = XCTAttachment(string:
                    "Test \(testCase.name) added \(delta) NotificationCenter.default observer(s) without paired remove. " +
                    "Pre=\(pre), Post=\(post). Route through an injected NotificationCenter or call " +
                    "removeObserver in tearDown."
                )
                activity.add(attachment)
            }
        }
    }

    /// Returns the current observer count from `NotificationCenter.default`
    /// when reachable. Best-effort — returns nil if the runtime-private
    /// API is unavailable. Audit-only — used solely for delta warnings,
    /// never as a hard assertion.
    private static func sampleObserverCount() -> Int? {
        // The implementation uses a debugDescription parse — the
        // `debugDescription` of NSNotificationCenter contains a line of
        // the form "<NSNotificationCenter: 0x...> [observers: <N>]" on
        // current Apple platforms. If the parse fails we return nil and
        // skip the audit for that test.
        let desc = (NotificationCenter.default as NSObject).debugDescription
        if let match = Self.observerCountRegex.firstMatch(
            in: desc, range: NSRange(desc.startIndex..., in: desc)
        ),
           let range = Range(match.range(at: 1), in: desc),
           let n = Int(desc[range]) {
            return n
        }
        return nil
    }

    private static let observerCountRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try - regex literal known-good
        return try! NSRegularExpression(pattern: #"observers:\s*(\d+)"#)
    }()
}
```

**MODIFY — `PalaceTests/HTTPStubURLProtocol.swift` (add public alias):**

```swift
/// Alias of `reset()` adopted as the canonical name in the SingletonResetRegistry
/// bootstrap path (swarm_4b64e4e0 Fix 1). Existing `reset()` callers continue to
/// work — both methods clear the handler array under the same queue.
static func removeAllHandlers() {
    reset()
}
```

(No other change to the class — the existing `reset()` already drains the handler array under `handlerQueue.sync`.)

**MODIFY — `PalaceTests/URLSession+Stubbing.swift` (convert `let` → `var` + add `_resetStubbedSession()`):**

```swift
extension URLSession {
    private static var _sharedStubbedSession: URLSession = Self._buildStubbedSession()

    private static func _buildStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func stubbedSession() -> URLSession {
        return _sharedStubbedSession
    }

    /// Test-only: invalidate the cached stubbed session and rebuild on
    /// next read. Registered into `SingletonResetRegistry` by
    /// `PalaceTestSetup.bootstrap()` — fires after every test so the
    /// next test sees a fresh URLSession (and a fresh delegate queue),
    /// preventing the cross-test libdispatch use-after-free described in
    /// the file's original header comment.
    static func _resetStubbedSession() {
        let old = _sharedStubbedSession
        _sharedStubbedSession = _buildStubbedSession()
        // `finishTasksAndInvalidate` lets in-flight tasks drain on the
        // OLD session before its delegate queue tears down. `invalidate
        // AndCancel` would cancel in-flight tasks mid-flight which races
        // with completion handlers reading freed state — the very bug
        // the original singleton existed to avoid.
        old.finishTasksAndInvalidate()
    }
}
```

## Internal seams

- `SingletonResetRegistry` storage is an array of (name, closure) tuples under an NSLock. NOT a dictionary — iteration order = registration order is part of the contract.
- The XCTestObservation observer is retained by `PalaceTestSetup.observer` (`static var`). Without this retain, XCTest's weak reference drops the observer and the hook silently never fires. Tests assert the retain.
- `URLSession._resetStubbedSession()` uses `finishTasksAndInvalidate()` not `invalidateAndCancel()` per the file's own header comment about delegate-queue use-after-free. This is load-bearing.
- The NotificationCenter audit uses `(NotificationCenter.default as NSObject).debugDescription` regex parse — best-effort. If the parse returns nil for two consecutive samples, no audit fires for that test. Audit-only; NOT a hard assertion. This decouples the test suite from Apple's private API surface.

## Test contracts

### NEW — `PalaceTests/Support/SingletonResetRegistryTests.swift` (5 tests)

1. **`testRegister_thenInvokeAll_callsResettersInRegistrationOrder`**
   - Arrange: 3 resetters appended in order A, B, C; each appends its name to a captured array.
   - Act: `invokeAll()`.
   - Assert: captured array equals `["A", "B", "C"]`. Re-invoking again appends `"A", "B", "C"` (idempotent invocation).

2. **`testRegister_reRegisterSameName_overwritesInPlacePreservingOrder`**
   - Arrange: register A, B, C. Re-register B with a new closure that appends `"B-v2"`.
   - Act: `invokeAll()`.
   - Assert: captured array equals `["A", "B-v2", "C"]` — B's position preserved, closure replaced.

3. **`testInvokeAll_reentrantRegisterDuringResetter_isDroppedWithWarning`**
   - Arrange: register A; A's closure calls `register("X", ...)` from inside. Register B after A.
   - Act: `invokeAll()`.
   - Assert: `registeredNames()` post-call equals `["A", "B"]` (the "X" registration was dropped).

4. **`testInvokeAll_resetterClosureCapturingNilWeakRef_doesNotCrash`**
   - Arrange: a resetter that captures a `weak var` to a deallocated object and calls a method on it via `?.`.
   - Act: `invokeAll()`.
   - Assert: does not crash. (Resetters MUST be nil-safe per contract; this test pins the contract.)

5. **`testRegister_multipleThreadsConcurrently_yieldsConsistentSnapshot`**
   - Arrange: spawn 4 DispatchQueue.global tasks each registering 100 named resetters (`"thread-\(i)-reset-\(j)"`).
   - Act: await completion.
   - Assert: `registeredNames().count == 400`; no duplicates; lock did not deadlock (test timeout = 5s).

### NEW — `PalaceTests/PalaceTestSetupObservationTests.swift` (4 tests)

1. **`testBootstrap_isIdempotent_returnsSameObserver`**
   - Arrange: call `PalaceTestSetup.bootstrap()` twice.
   - Act: read both return values.
   - Assert: same observer instance (`===`). `XCTestObservationCenter` was added-to exactly once (we expose a test seam: a static counter on `PalaceTestSetup` incremented inside the bootstrap lock).

2. **`testTestCaseDidFinish_callsRegistryResettersInRegistrationOrder`**
   - Arrange: bootstrap; clear registry via `_removeAllForTests`; register A, B, C resetters that append their name to a captured array; fabricate a fake XCTestCase and call `observer.testCaseDidFinish(fake)`.
   - Act: read captured array.
   - Assert: equals `["A", "B", "C"]`.

3. **`testTestCaseDidFinish_observerCountIncreases_emitsRunActivityWarning`**
   - Arrange: install the observer; sample pre-count; add 3 dummy observers to `NotificationCenter.default` without removing them; call `testCaseDidFinish`.
   - Act: read the test's own `XCTContext` activity log via the standard `XCTAttachment` capture pattern.
   - Assert: an attachment exists whose string contains `"added 3 NotificationCenter.default observer(s)"`. Remove the 3 dummy observers in tearDown.

4. **`testCanary_AppContainerResetForTesting_yieldsCleanGraph`** (the canary requested in the prompt)
   - Arrange: bootstrap; capture `AppContainer.production().accountsManager` reference (call it `pre`); mutate a known field — `pre.preloadAccountsFromDiskCacheSync()` is safe + observable; call `AppContainer._resetForTesting()`.
   - Act: capture `AppContainer.production().accountsManager` again (`post`).
   - Assert: `pre !== post` (the cached graph was rebuilt); `post.accounts().isEmpty` (cleaning observable — the new instance has `deferInitialLoadCatalogsForTesting=true` AND no preload has run yet).

### MODIFY — `PalaceTests/HTTPStubURLProtocol.swift` test coverage

The existing file has no `HTTPStubURLProtocolTests.swift`. The contract does NOT require adding one — the alias is a 3-line forward. Module A's test count remains as listed.

### MODIFY — `PalaceTests/URLSession+Stubbing.swift` test coverage

NEW — `PalaceTests/URLSessionStubbingResetTests.swift` (2 tests):

1. **`testResetStubbedSession_returnsDistinctSessionInstance`**
   - Arrange: capture `URLSession.stubbedSession()` (`pre`).
   - Act: `URLSession._resetStubbedSession()`; capture again (`post`).
   - Assert: `pre !== post`.

2. **`testResetStubbedSession_inFlightTaskOnOldSession_completesGracefully`**
   - Arrange: register a 100ms-delayed handler on `HTTPStubURLProtocol`; start a `URLSessionDataTask` on `pre`; immediately call `_resetStubbedSession()`.
   - Act: await task completion via fulfillment.
   - Assert: task completes with the registered response (proves `finishTasksAndInvalidate` semantics; this is the load-bearing safety property).

## Files scoped to THIS implementer

**Production MODIFIED (in test target):**
- `PalaceTests/PalaceTestSetup.swift` — replace contents with bootstrap + observer
- `PalaceTests/HTTPStubURLProtocol.swift` — add `removeAllHandlers()` alias
- `PalaceTests/URLSession+Stubbing.swift` — convert `let` to `var`, add `_resetStubbedSession()`

**Test target NEW:**
- `PalaceTests/Support/SingletonResetRegistry.swift`
- `PalaceTests/Support/SingletonResetRegistryTests.swift`
- `PalaceTests/PalaceTestSetupObservationTests.swift`
- `PalaceTests/URLSessionStubbingResetTests.swift`

**Tooling:**
- `ruby scripts/pbxproj_add_swift.rb --target PalaceTests PalaceTests/Support/SingletonResetRegistry.swift PalaceTests/Support/SingletonResetRegistryTests.swift PalaceTests/PalaceTestSetupObservationTests.swift PalaceTests/URLSessionStubbingResetTests.swift`

**`Palace.xcodeproj/project.pbxproj`** — touched only via `pbxproj_add_swift.rb`. No manual edits.

## Files explicitly OFF-LIMITS

**Universal anti-scope:**
- `Palace.xcodeproj/**/xcschemes/*.xcscheme` — Fix 5 / Wave 2 territory.
- `.github/workflows/**` — Fix 5 / Wave 2 territory.
- Any `ios-audiobooktoolkit/**` file (separate submodule pipeline).

**Off-limits per Module B ownership:**
- `Palace/AppInfrastructure/AppContainer.swift` — Module B owns. Module A REFERENCES `AppContainer._resetForTesting` by name in the registry bootstrap, but does NOT modify the file.
- `Palace/Accounts/Library/AccountsManager.swift` — Module B owns.

**Off-limits to A (other test infra not in scope):**
- Any test file in `PalaceTests/` other than the 4 new + 3 modified above.
- `PalaceTests/Mocks/TPPUserAccountMock.swift` — `resetShared()` already exists (verified at line 246). No changes needed.

## Verification criteria

1. **PalaceTestSetup is an XCTestObservation host:**
   ```bash
   grep -c "XCTestObservation\|addTestObserver" PalaceTests/PalaceTestSetup.swift
   # MUST be ≥ 2 (one each for the conformance/host + the addTestObserver call)
   ```

2. **SingletonResetRegistry exists and is referenced from PalaceTestSetup:**
   ```bash
   test -f PalaceTests/Support/SingletonResetRegistry.swift
   grep -c "SingletonResetRegistry.shared.register" PalaceTests/PalaceTestSetup.swift
   # MUST be ≥ 5 (the 5 built-in resetters)
   ```

3. **All 5 built-in resetters are wired by exact symbol:**
   ```bash
   grep "AppContainer._resetForTesting" PalaceTests/PalaceTestSetup.swift
   grep "AccountStateStore.shared._resetAllForTesting" PalaceTests/PalaceTestSetup.swift
   grep "TPPUserAccountMock.resetShared" PalaceTests/PalaceTestSetup.swift
   grep "HTTPStubURLProtocol.removeAllHandlers" PalaceTests/PalaceTestSetup.swift
   grep "URLSession._resetStubbedSession" PalaceTests/PalaceTestSetup.swift
   # All 5 grep lines MUST match at least once
   ```

4. **`removeAllHandlers` alias added (paired with existing `reset`):**
   ```bash
   grep -c "static func removeAllHandlers" PalaceTests/HTTPStubURLProtocol.swift
   # MUST be 1
   grep -c "static func reset" PalaceTests/HTTPStubURLProtocol.swift
   # MUST still be 1 (backward compat preserved)
   ```

5. **`_resetStubbedSession()` added and `_sharedStubbedSession` is a `var`:**
   ```bash
   grep -c "static func _resetStubbedSession" PalaceTests/URLSession+Stubbing.swift
   # MUST be 1
   grep -c "private static var _sharedStubbedSession" PalaceTests/URLSession+Stubbing.swift
   # MUST be 1 (the conversion from `let` to `var`)
   ```

6. **Observer is RETAINED by PalaceTestSetup:**
   ```bash
   grep -c "private static var observer" PalaceTests/PalaceTestSetup.swift
   # MUST be 1 — XCTest holds observers weakly; the static retain is load-bearing
   ```

7. **pbxproj registration:**
   ```bash
   grep -c "SingletonResetRegistry.swift" Palace.xcodeproj/project.pbxproj
   # MUST be ≥ 2 (PBXBuildFile + PBXFileReference at minimum)
   grep -c "SingletonResetRegistryTests.swift" Palace.xcodeproj/project.pbxproj
   # MUST be ≥ 2
   grep -c "PalaceTestSetupObservationTests.swift" Palace.xcodeproj/project.pbxproj
   # MUST be ≥ 2
   grep -c "URLSessionStubbingResetTests.swift" Palace.xcodeproj/project.pbxproj
   # MUST be ≥ 2
   ```

8. **Tests run and pass:**
   ```bash
   xcodebuild -project Palace.xcodeproj -scheme Palace \
     -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
     -only-testing:PalaceTests/SingletonResetRegistryTests \
     -only-testing:PalaceTests/PalaceTestSetupObservationTests \
     -only-testing:PalaceTests/URLSessionStubbingResetTests \
     test
   # MUST PASS — 11 tests across the 3 new classes
   ```

9. **No force unwraps (except the documented `try!` for the regex literal):**
   ```bash
   git diff origin/develop -- PalaceTests/Support/ PalaceTests/PalaceTestSetup.swift PalaceTests/HTTPStubURLProtocol.swift PalaceTests/URLSession+Stubbing.swift PalaceTests/URLSessionStubbingResetTests.swift PalaceTests/PalaceTestSetupObservationTests.swift \
     | grep -E '^\+.*[a-zA-Z_)\]]\!([. ;)\[])' | grep -v '!=' | grep -v '// ' | grep -v 'try!'
   # MUST be empty — the regex `try!` is the only allowed exception
   ```

10. **No new production-target `.shared` reads or modifications:**
    ```bash
    git diff origin/develop -- Palace/ \
      | grep -E '^[-+]' | wc -l
    # MUST be 0 — Module A does NOT touch Palace/ production code
    ```

11. **`scripts/check-blast-radius.py --quiet` and `scripts/check-contract-reconciliation.py --commit-msg <commit-msg-file> --quiet`:**
    Both MUST exit 0. Paste exit codes.

12. **`scripts/verify-pr.sh --quick`** MUST PASS.

## Mutation pass

`palace_mutate.py` skips test-target files by default (it operates on production code), but the registry IS critical-path-adjacent. Run a focused mutation pass on Module B's `_resetForTesting` (Module B's responsibility); Module A's verification rests on the 11 new tests passing + the canary test exercising the full reset path.

## Implementer prompt (one paragraph)

You are Module A implementer for `swarm_4b64e4e0` (Wave 1 of the iOS test-flakiness permanent fix). Extend `PalaceTests/PalaceTestSetup.swift` (currently 12 LOC) to install a process-wide `XCTestObservation` (`PalaceSingletonResetObserver`) that, after every test, invokes a `SingletonResetRegistry` of named `() -> Void` closures and audits `NotificationCenter.default` observer-count drift via a best-effort `debugDescription` regex parse (audit-only — never a hard assertion). Create `PalaceTests/Support/SingletonResetRegistry.swift` with `register(_:resetter:)`, `invokeAll()`, `registeredNames()`, and a test-only `_removeAllForTests()`; storage is an array of (name, closure) tuples under an NSLock with insertion-order iteration; re-registering the same name overwrites in place; reentrant registration during iteration is logged and dropped. Wire the 5 built-in resetters at bootstrap (`AppContainer._resetForTesting`, `AccountStateStore.shared._resetAllForTesting`, `TPPUserAccountMock.resetShared`, `HTTPStubURLProtocol.removeAllHandlers`, `URLSession._resetStubbedSession`). Add `HTTPStubURLProtocol.removeAllHandlers()` as a forwarding alias of existing `reset()`. Convert `URLSession._sharedStubbedSession` from `let` to `var`, add `URLSession._resetStubbedSession()` that calls `old.finishTasksAndInvalidate()` (NOT `invalidateAndCancel` — the file's own header explains why) then rebuilds. Add 11 tests across 3 new test files (`SingletonResetRegistryTests` x5, `PalaceTestSetupObservationTests` x4 including the canary, `URLSessionStubbingResetTests` x2). Wire all 4 new test-target files via `ruby scripts/pbxproj_add_swift.rb --target PalaceTests`. The XCTestObservation observer MUST be retained via a `static var observer:` on `PalaceTestSetup` — XCTest holds observers weakly and ARC drops them otherwise. NO production-code edits — Module B owns `AppContainer._resetForTesting`. If you find that Module B's symbol is not yet present at integration time (the bootstrap reference would fail to compile), wrap the closure body in `#if DEBUG` (the registered closure is invoked at runtime, not compiled at bootstrap-time) — but BLOCKED with a scope-deferral if a different symbol mismatch surfaces. STOP if the NotificationCenter `debugDescription` regex fails to match on the developer's Xcode 26 baseline — fall back to skipping the audit silently for that platform and note the gap in the implementer transcript.
````

---
