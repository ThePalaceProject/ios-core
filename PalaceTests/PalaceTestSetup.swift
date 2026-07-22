import Foundation
import XCTest
@testable import Palace

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
class PalaceTestSetup: NSObject {
    private static let bootstrapLock = NSLock()

    /// Strong reference to the observer. XCTest holds it weakly; without
    /// our retain, ARC drops the observer immediately after
    /// `addTestObserver(_:)` returns and `testCaseDidFinish(_:)` never
    /// fires. This `static var` retain is load-bearing.
    private static let _observer = LockIsolated<PalaceSingletonResetObserver?>(nil)
    private static var observer: PalaceSingletonResetObserver? {
        get { _observer.value }
        set { _observer.value = newValue }
    }

    override init() {
        super.init()
        _ = Self.bootstrap()
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

        // #3 hermeticity: `NoNetworkURLProtocol.enable()` (above) registers the
        // stub for `URLSession.shared`, but the SHARED `TPPNetworkExecutor` builds
        // its own `URLSession(configuration:)`, which consults only
        // `config.protocolClasses` — so `AccountsManager.fallbackDirectRefresh`
        // (and any executor GET) would escape to the real
        // `registry.palaceproject.io` in tests. Install the stub onto the
        // executor's config via AppContainer's non-DEBUG test seam.
        AppContainer.testExecutorProtocolClasses = [NoNetworkURLProtocol.self]

        // swarm_4b64e4e0 Wave 1d fix — pin the
        // `deferInitialLoadCatalogsForTesting` flag to `true` BEFORE any test
        // can lazy-trigger `AppContainer.production()`. Without this, the
        // very first cached AppContainer (built by any incidental
        // `AppContainer.production()` call — there are dozens of default-arg
        // sites) fires its `AccountsManager.init` background `loadCatalogs`
        // Task with the flag at its default `false`. That Task then runs the
        // bundled-registry cold-load path and the network refresh, writing
        // 1142+ bundled account entries to `accounts_catalog_<hash>.json`
        // on disk — OVERWRITING any 171-account fixture seed a wiring test
        // later writes to the same hash, mid-test. The result is the failure
        // mode `testDriveCurrentAccountAuthDoc_terminalState_isNoOp` ::
        // `Setup: currentAccount must resolve after preload` — the test's
        // explicit `preloadAccountsFromDiskCacheSync()` parses the BUNDLED
        // 1142 accounts (none of which carry the fixture's UUID space) and
        // `account(currentUUID)` returns nil. Tests that need the background
        // `loadCatalogs` to fire (e.g. `AppContainerResetTests`) explicitly
        // flip the flag back to `false` in their own setUp. Wiring suite
        // tests inherit `true` and stay deterministic. See the wave 1d
        // transcript for the full forensic.
        #if DEBUG
        AccountsManager.deferInitialLoadCatalogsForTesting = true
        #endif

        let obs = PalaceSingletonResetObserver()
        XCTestObservationCenter.shared.addTestObserver(obs)
        observer = obs

        registerBuiltInResetters()

        // #3 (cont.): the host Palace app has ALREADY built the cached
        // `AppContainer` (and its network executor) during app launch — which
        // happened BEFORE this test-bundle principal class loaded and set
        // `testExecutorProtocolClasses` above. So that launch-built executor does
        // NOT have NoNetworkURLProtocol installed; without a rebuild, the FIRST
        // test in any run (which has no prior `_resetForTesting` to rebuild the
        // graph) would use it and escape to the real network. Rebuild the cached
        // graph now, with the seam set, so EVERY test (including the first) gets
        // an executor routed through the stub. Subsequent per-test
        // `_resetForTesting` calls keep it. Runs on the main thread (principal
        // class load). NON-#if-DEBUG on purpose: the test build uses a config
        // WITHOUT `DEBUG` defined (PalaceTests' `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
        // is `LCP FEATURE_OVERDRIVE`), so a `#if DEBUG` guard here would compile
        // out and skip the rebuild — measured: the executor then keeps the
        // launch-built session with no stub. `_rebuildCachedForTestProtocols()`
        // is a plain internal seam (no #if DEBUG), reachable via @testable import.
        AppContainer._rebuildCachedForTestProtocols()

        return obs
    }

    /// Built-in resetter list. Order matters: AppContainer is rebuilt
    /// FIRST so subsequent resetters see a clean graph; the static
    /// resetters then clear residue that may have been written via
    /// direct singleton mutation in the just-finished test.
    ///
    /// `AppContainer._resetForTesting()` is owned by Module B
    /// (swarm_4b64e4e0). The registration closure references the symbol
    /// at the body, NOT at registration time — so as long as the symbol
    /// exists when the bundle loads (which is also when the closure
    /// would first run), the registry resolves. The `#if DEBUG` guard
    /// matches the symbol's own gate.
    private static func registerBuiltInResetters() {
        let registry = SingletonResetRegistry.shared

        registry.register("AppContainer._resetForTesting") {
            #if DEBUG
            // Module B's `Palace/AppInfrastructure/AppContainer.swift`
            // exposes `internal static func _resetForTesting()` under
            // `#if DEBUG`. The function is `@MainActor`-isolated so we hop
            // to MainActor synchronously via `MainActor.assumeIsolated` —
            // the observer's `testCaseDidFinish(_:)` already runs on the
            // main thread (XCTest dispatches it there), so the assumption
            // is sound at runtime. swarm_4b64e4e0 Module A integrated with
            // Module B.
            MainActor.assumeIsolated {
                AppContainer._resetForTesting()
            }
            #endif
        }

        // Drain EVERY live AccountsManager's background work at the boundary —
        // not just the shared one AppContainer recreates. The root of the
        // order-dependent Accounts-suite flakes is a pending `DispatchQueue.main.async`
        // auth-doc drive (from `preloadAccountsFromDiskCacheSync`'s deferred
        // `driveCurrentAccountAuthDocIfNeeded()`) enqueued at EVERY AccountsManager
        // init — including foreign instances built by test helpers. It is NOT a
        // Task, so `cancelBackgroundWork()` can't stop it; left un-flushed it fires
        // on a later runloop turn INSIDE the next test and writes a fixture library
        // UUID's `.detailsLoading`/`.detailsFailed` into it. `cancelAndDrainBackgroundWork`
        // (invoked per live instance by `_drainAllLiveInstancesForTesting`) PUMPS
        // the main run loop (bounded) so every such pending hop fires NOW, inside
        // the boundary — after `AppContainer._resetForTesting` above (so the
        // just-recreated shared instance is included) and BEFORE the store reset
        // below (so any flushed late-write is then wiped). This is the missing wire:
        // the drain existed but ran only in one bespoke test, never per-boundary.
        registry.register("AccountsManager._drainAllLiveInstancesForTesting") {
            #if DEBUG
            AccountsManager._drainAllLiveInstancesForTesting()
            #endif
        }

        registry.register("AccountStateStore.shared._resetAllForTesting") {
            AccountStateStore.shared._resetAllForTesting()
        }

        registry.register("TPPUserAccountMock.resetShared") {
            TPPUserAccountMock.resetShared()
        }

        registry.register("HTTPStubURLProtocol.removeAllHandlers") {
            HTTPStubURLProtocol.removeAllHandlers()
        }

        registry.register("URLSession._resetStubbedSession") {
            URLSession._resetStubbedSession()
        }

        // Restore ImageCache.shared's processing queue after every test.
        // ImageCacheContinuationTests suspends the shared queue; without this
        // fallback a mid-suspend abort would leave it suspended and hang every
        // later getAsync — a whole-suite test-isolation hazard.
        registry.register("ImageCache._resetForTesting") {
            ImageCache.shared._resetForTesting()
        }

        // Clear the process-global MockBackend config after every test.
        // `MockBackendTestHelper.activate(...)` sets these statics in setUp
        // and clears them in the test's own tearDown; a test that aborts
        // before tearDown leaks an `activeScenario`, and `canInit(with:)`
        // (gated on `activeScenario != nil`) then intercepts EVERY later
        // request — serving fixtures / canned 401s and corrupting
        // network-dependent tests. This is the un-reset twin of the
        // registered `HTTPStubURLProtocol.removeAllHandlers`. Pure,
        // synchronous clear (no `MockBackendService.shared.deactivate()`,
        // which would recreate the session on the MainActor).
        //
        // NOT `#if DEBUG`-gated: the PalaceTests target does not define
        // DEBUG (its compilation conditions are "LCP FEATURE_OVERDRIVE").
        // The protocol's `#if DEBUG` gate is on the *Palace* module, which
        // the test bundle links via `@testable import Palace` after Palace
        // is built in Debug — so these statics are always visible here.
        // `MockBackendTestHelper` already references them unconditionally.
        registry.register("MockBackendURLProtocol._resetForTesting") {
            MockBackendURLProtocol.activeScenario = nil
            MockBackendURLProtocol.scopedHost = nil
            MockBackendURLProtocol.fixtureDirectoryPath = nil
            MockBackendURLProtocol.fixtureBundle = .main
        }

        // Clear the process-global Chaos fault plan after every test. A
        // ChaosURLProtocol test that aborts before tearDown leaves a leaked
        // `_plan`, which then faults later requests. `reset()` is a fast,
        // synchronous clear that also invalidates any leaked chaos sessions.
        registry.register("ChaosURLProtocol.reset") {
            ChaosURLProtocol.reset()
        }
    }
}

// MARK: - PalaceSingletonResetObserver

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
class PalaceSingletonResetObserver: NSObject, XCTestObservation {
    /// Baseline NotificationCenter observer count sampled at
    /// `testCaseWillStart`. The audit compares against this on
    /// `testCaseDidFinish`. Best-effort — if the runtime-private API
    /// isn't reachable, this is nil and the audit is silently skipped.
    private var preCount: Int?

    /// Last computed `post - pre` delta. Exposed for the observation
    /// tests; the regular reset path does NOT depend on this value.
    /// Nil if the audit was skipped (regex parse returned nil for either
    /// sample).
    internal var lastObservedDeltaForTesting: Int?

    func testCaseWillStart(_ testCase: XCTestCase) {
        preCount = Self.sampleObserverCount()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // Diagnostic breadcrumb (NOT a gate): if a test left the suite
        // non-quiescent, name it loudly in the run log BEFORE the reset below
        // scrubs the evidence. This is intentionally NOT an enforcement point —
        // `XCTestCase.record(_:)` from testCaseDidFinish is empirically inert
        // (it does not fail an already-finished test; verified by the WS-0
        // synthetic-polluter wiring proof), and a non-failing "gate" is the
        // canonical inert-gate anti-pattern this codebase has been burned by.
        // The REAL, deterministic enforcement lives in
        // `PalaceTestCase.tearDownWithError` (runtime XCTFail, order-independent)
        // plus `RuntimeQuiescenceLintTests` (structural — forces any test that
        // sets the defer flag false onto a quiescence-gated base). This line
        // only helps a human reading CI logs spot a polluter that somehow
        // slipped both — it claims nothing it cannot deliver.
        for violation in RuntimeQuiescenceAuditor.auditLiveState() {
            NSLog("[WS0-QUIESCENCE-DIAG] %@ left the suite non-quiescent [%@] — see PalaceTestCase / RuntimeQuiescenceLintTests for the enforcing gates.",
                  testCase.name, violation.invariant)
        }

        // WS-0 pool-responsiveness DIAGNOSTIC (warn-only, NOT a gate yet).
        // Measures, off the cooperative pool, how long it takes the pool to
        // schedule a high-priority probe Task right after this test. A free
        // pool answers in <5ms; a pool saturated by a prior test's leaked
        // blocking/un-drained Tasks answers slowly or times out — the
        // accumulation pool-starvation class (class 4) that reds CI on unlucky
        // shuffles. Logging EVERY test's latency lets the analysis find the
        // ONSET of the latency climb (closer to the actual leaker than the
        // eventual hung victim). Captured BEFORE invokeAll() so it reflects the
        // state THIS test left. The probe adds a single Task — it does not
        // perturb the pool it measures. Promotion to a hard PalaceTestCase
        // tearDown gate happens only after this confirms no false positives.
        let poolProbe = Self.measureCooperativePoolProbe(budget: 2.0)
        if !poolProbe.completed || poolProbe.latencyMs >= 20 {
            NSLog("[WS0-POOL-DIAG] %@ pool-probe latencyMs=%d completed=%@",
                  testCase.name, poolProbe.latencyMs, poolProbe.completed ? "true" : "false")
        }

        SingletonResetRegistry.shared.invokeAll()

        guard let pre = preCount, let post = Self.sampleObserverCount() else {
            preCount = nil
            lastObservedDeltaForTesting = nil
            return
        }
        preCount = nil
        let delta = post - pre
        lastObservedDeltaForTesting = delta
        if delta > 0 {
            // Swift 6: capture the name (Sendable String) so the runActivity
            // closure doesn't send the non-Sendable `testCase` across a boundary.
            let testCaseName = testCase.name
            XCTContext.runActivity(named: "NotificationCenter observer leak (\(delta) net adds)") { activity in
                let attachment = XCTAttachment(string:
                    "Test \(testCaseName) added \(delta) NotificationCenter.default observer(s) without paired remove. " +
                    "Pre=\(pre), Post=\(post). Route through an injected NotificationCenter or call " +
                    "removeObserver in tearDown."
                )
                activity.add(attachment)
            }
        }
    }

    /// WS-0 pool-responsiveness probe. Measures, from the MAIN thread, how long
    /// the cooperative thread pool takes to schedule a high-priority probe Task.
    ///
    /// `XCTWaiter().wait` blocks the MAIN thread (not a pool worker), so if the
    /// pool has any free thread the probe Task runs and we get the latency; if
    /// the pool is fully saturated by leaked blocking Tasks the probe never runs
    /// and we time out at `budget`. One probe Task adds negligible pressure — it
    /// does not perturb what it measures. Returns whether the probe completed
    /// and its latency in milliseconds (== budget on timeout).
    static func measureCooperativePoolProbe(budget: TimeInterval) -> (completed: Bool, latencyMs: Int) {
        let start = DispatchTime.now()
        let probe = XCTestExpectation(description: "WS0 cooperative-pool probe")
        Task.detached(priority: .high) { probe.fulfill() }
        let result = XCTWaiter().wait(for: [probe], timeout: budget)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return (result == .completed, Int(elapsedNs / 1_000_000))
    }

    /// Returns the current observer count from `NotificationCenter.default`
    /// when reachable. Best-effort — returns nil if the runtime-private
    /// API is unavailable. Audit-only — used for delta warnings here and by
    /// `PalaceTestCase`'s per-test observer-leak gate (warn-only until the
    /// false-positive audit clears promotion to a hard XCTFail).
    static func sampleObserverCount() -> Int? {
        // The implementation uses a `debugDescription` parse — the
        // `debugDescription` of NSNotificationCenter contains a line of
        // the form `<NSNotificationCenter: 0x...> observers: <N>` on
        // current Apple platforms. If the parse fails we return nil and
        // skip the audit for that test.
        let desc = (NotificationCenter.default as NSObject).debugDescription
        guard let regex = Self.observerCountRegex else { return nil }
        let nsRange = NSRange(desc.startIndex..., in: desc)
        if let match = regex.firstMatch(in: desc, range: nsRange),
           let range = Range(match.range(at: 1), in: desc),
           let n = Int(desc[range]) {
            return n
        }
        return nil
    }

    private static let observerCountRegex: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"observers:\s*(\d+)"#)
    }()
}
