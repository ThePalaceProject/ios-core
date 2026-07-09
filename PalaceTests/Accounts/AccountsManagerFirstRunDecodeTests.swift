//
//  AccountsManagerFirstRunDecodeTests.swift
//  PalaceTests
//
//  CP-D3 (FirstRunDecode) tests for the cold-first-launch bundled-registry
//  decode in `AccountsManager.loadCatalogs`.
//
//  The bug: on a fresh install (no on-disk catalog cache) two callers race
//  into `loadCatalogs` — the background init arm AND
//  `TPPAppDelegate.presentFirstRunFlowIfNeeded` (@MainActor) — and BOTH reach
//  the ~2.4 MB bundled-snapshot decode because the dedupe guard sat AFTER the
//  bundled branch. The @MainActor caller decoded on the main thread.
//
//  The fix (with the Phase 1a correction): a SINGLE dedupe guard placed ABOVE
//  the bundled branch (so a concurrent second caller short-circuits before the
//  decode) that is NOT re-checked before the network fetch (re-checking there
//  would make the first caller observe its own registration and `return`
//  before the network ever fires — stranding the picker on stale bundled data
//  until next launch), plus hopping the bundled decode off the main thread.
//
//  These three tests pin the contract:
//    1. Dedupe-before-bundled — a second concurrent load short-circuits BEFORE
//       the bundled decode (the decode runs exactly once).
//    2. Network-fetch-still-fires (the Phase-1a-critical one) — the network
//       fetch still fires exactly once AFTER the bundled decode. A dedupe that
//       swallows the fetch (the regression the naive fix would ship) leaves
//       the fetch count at 0 and fails this test.
//    3. Off-main — the bundled decode does not run on the main thread.
//
//  Isolation is inherited from `PalaceWiringTestCase`: per-test
//  `SingletonResetRegistry.invokeAll()`, `deferInitialLoadCatalogsForTesting`,
//  `cancelBackgroundWork()` on every helper-minted manager in tearDown, and an
//  Application-Support `accounts_catalog_*` purge in setUp + tearDown. The
//  manager's bundled-snapshot loader is injected via the production
//  `snapshotResourceResolver` seam so the tests observe the decode's thread +
//  invocation count against a tiny fixture feed — no 2.4 MB real snapshot, no
//  network dependency for the bundled leg.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountsManagerFirstRunDecodeTests: PalaceWiringTestCase {

    // MARK: - Stub resolver

    /// `BundleResourceResolving` stub that records how many times the bundled
    /// snapshot was resolved and on which thread, and hands back a tiny fixture
    /// feed instead of the real 2.4 MB bundle resource. `@unchecked Sendable`:
    /// all mutable state is guarded by `lock`; the closure is only read.
    private final class CountingSnapshotResolver: BundleResourceResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        private var _lastCallOnMainThread: Bool?
        private let snapshotURL: URL?
        private let onResolve: () -> Void

        init(snapshotURL: URL?, onResolve: @escaping () -> Void = {}) {
            self.snapshotURL = snapshotURL
            self.onResolve = onResolve
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _callCount
        }

        var lastCallOnMainThread: Bool? {
            lock.lock(); defer { lock.unlock() }
            return _lastCallOnMainThread
        }

        func resourceURL(forName name: String, extension ext: String) -> URL? {
            lock.lock()
            _callCount += 1
            _lastCallOnMainThread = Thread.isMainThread
            lock.unlock()
            onResolve()
            guard name == BundledRegistrySnapshot.resourceName,
                  ext == BundledRegistrySnapshot.resourceExtension else {
                return nil
            }
            return snapshotURL
        }
    }

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("firstrun_decode_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Writes a minimal-but-valid OPDS 2.0 catalogs feed (zero catalogs, so the
    /// downstream `loadAccountSetsAndAuthDoc` does no per-account network) to a
    /// temp file and returns its URL for the stub resolver to hand back.
    private func writeStubSnapshot() throws -> URL {
        let payload = #"{"metadata":{"title":"CP-D3 stub"},"catalogs":[],"links":[]}"#
        let url = tempDir
            .appendingPathComponent("\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)")
        try payload.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Isolated defaults suite so `currentAccountIdentifierKey` reads during
    /// init/preload can never resolve a real account from `.standard` and flip
    /// the manager onto the warm memory path instead of the fresh-install
    /// bundled path.
    private func isolatedDefaults() -> UserDefaults {
        let name = "cp-d3.firstrun.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Spin the run loop until `condition` is true or the deadline passes.
    /// Used to observe the off-main first-run task's synchronous counters from
    /// the main test thread without a fixed sleep.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - 1. Dedupe fires BEFORE the bundled decode

    /// A second load arriving while the first is still in flight must
    /// short-circuit on the consolidated dedupe guard — which sits ABOVE the
    /// bundled branch — so the ~2.4 MB bundled snapshot is decoded exactly
    /// once, not once per caller.
    func testSecondConcurrentLoad_shortCircuitsBeforeBundledDecode() throws {
        let snapshotURL = try writeStubSnapshot()
        let decodeRan = expectation(description: "bundled snapshot resolved")
        decodeRan.expectedFulfillmentCount = 1
        // A broken dedupe (decode runs per caller) over-fulfills → test fails.
        decodeRan.assertForOverFulfill = true
        let resolver = CountingSnapshotResolver(snapshotURL: snapshotURL) {
            decodeRan.fulfill()
        }

        let defaults = isolatedDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults) {
            $0.snapshotResourceResolver = resolver
        }

        // First load registers the dedupe handler synchronously, then spawns
        // the off-main first-run task that decodes the bundled snapshot.
        manager.loadCatalogs(completion: nil)
        // Second load: the dedupe handler is already registered (the barrier
        // write from the first call is ordered before this call's synchronous
        // read), so this MUST short-circuit before the bundled branch — no
        // second first-run task, no second decode.
        manager.loadCatalogs(completion: nil)

        wait(for: [decodeRan], timeout: 5)
        // Settle briefly so an (erroneous) second decode would have a chance to
        // bump the counter before we assert.
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(resolver.callCount, 1,
                       "Bundled snapshot must be decoded exactly once; the second concurrent load must dedupe before the decode")

        manager.cancelBackgroundWork()
    }

    // MARK: - 2. Network fetch still fires after the bundled decode (Phase 1a)

    /// The bundled snapshot is a fast-path, NOT a replacement. After decoding
    /// it, `loadCatalogs` must still fire the network fetch exactly once. The
    /// naive "move the dedupe up" fix would make the first caller observe its
    /// own registration and `return` before the fetch — leaving this counter
    /// at 0 and stranding the picker on stale bundled data. This test fails
    /// loudly on that regression.
    func testFirstRun_networkFetchStillFiresOnce_afterBundledDecode() throws {
        let snapshotURL = try writeStubSnapshot()
        let resolver = CountingSnapshotResolver(snapshotURL: snapshotURL)

        let defaults = isolatedDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults) {
            $0.snapshotResourceResolver = resolver
        }

        XCTAssertEqual(manager.fetchFromNetworkCountForTesting, 0,
                       "precondition: no fetch before loadCatalogs")

        manager.loadCatalogs(completion: nil)

        // The fetch is dispatched from the off-main first-run task AFTER the
        // bundled decode. A swallowed fetch keeps this at 0 → the wait fails.
        let fired = waitUntil { manager.fetchFromNetworkCountForTesting >= 1 }
        XCTAssertTrue(fired, "Network fetch must fire after the bundled decode — it appears to have been swallowed by the dedupe")
        XCTAssertEqual(manager.fetchFromNetworkCountForTesting, 1,
                       "Network fetch must fire exactly once")
        XCTAssertEqual(resolver.callCount, 1,
                       "The bundled snapshot must have been decoded once before the network fetch (fetch fires AFTER it, not instead of it)")

        manager.cancelBackgroundWork()
    }

    // MARK: - 3. Bundled decode runs off the main thread

    /// Driving `loadCatalogs` from the main test thread, the bundled decode
    /// must be hopped off-main — otherwise the ~2.4 MB decode blocks the main
    /// thread on cold first launch (the original bug via
    /// `presentFirstRunFlowIfNeeded`).
    func testFirstRun_bundledDecode_runsOffMainThread() throws {
        let snapshotURL = try writeStubSnapshot()
        let decodeRan = expectation(description: "bundled snapshot resolved")
        let resolver = CountingSnapshotResolver(snapshotURL: snapshotURL) {
            decodeRan.fulfill()
        }
        decodeRan.expectedFulfillmentCount = 1
        decodeRan.assertForOverFulfill = false

        let defaults = isolatedDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults) {
            $0.snapshotResourceResolver = resolver
        }

        XCTAssertTrue(Thread.isMainThread, "test drives loadCatalogs from the main thread")
        manager.loadCatalogs(completion: nil)

        wait(for: [decodeRan], timeout: 5)
        XCTAssertEqual(resolver.lastCallOnMainThread, false,
                       "The bundled snapshot decode must not run on the main thread")

        manager.cancelBackgroundWork()
    }
}
