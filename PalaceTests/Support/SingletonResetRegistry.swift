import Foundation

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
///
/// Storage is an array of `(name, closure)` tuples — NOT a dictionary —
/// because iteration order = registration order is part of the contract.
/// `@unchecked Sendable`: all mutable stored state (`resetters`, `isIterating`)
/// is guarded by `lock` — every read/write path acquires it before touching
/// storage (`register`, `registeredNames`, `invokeAll`, `_removeAllForTests`).
/// The compiler can't see the lock, but the type guarantees it, so `static let
/// shared` is safe to share across concurrency domains.
internal class SingletonResetRegistry: @unchecked Sendable {
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
    /// `PalaceSingletonResetObserver.testCaseDidFinish(_:)`. The iteration
    /// runs on a snapshot of the resetter array — re-entrant registration
    /// is dropped by `register(_:resetter:)` based on the `isIterating`
    /// flag, so a snapshot is sufficient (and avoids holding the lock while
    /// resetter closures run, which would deadlock any closure that happens
    /// to read the registry).
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
