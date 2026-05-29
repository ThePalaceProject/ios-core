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
    private static var observer: PalaceSingletonResetObserver?

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
