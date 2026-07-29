//
//  AccountsManagerCatalogLoadJoinTests.swift
//  PalaceTests
//
//  PP-4754 root-fix tests for the OWNED, deterministically-joinable catalog
//  crawl. Drives the real cold-load spawn chain fully OFFLINE (the test host
//  routes `URLSession.shared` + the network executor through
//  `NoNetworkURLProtocol`, so both the registry crawler and the fallback GET
//  fail fast) and asserts:
//
//   1. The whole-set join seam `_awaitCatalogLoadForTesting()` drives every
//      owned crawl Task — init/first-run → crawl → fallback GET — to quiescence
//      with NO wall-clock (grow-until-stable Task-join). After it returns, the
//      owned set is empty.
//   2. The scheduling contract: the first-run task is a detached `.utility`
//      spawn, the crawl an inheriting `.userInitiated` spawn, and — the crux of
//      the fix — the fallback GET is now an OWNED detached `.utility` spawn
//      (previously a fire-and-forget closure the drain could not await).
//   3. Drain completeness: `cancelAndDrainBackgroundWork()` leaves the owned set
//      empty — the wrapped fallback GET is awaited, not leaked past the boundary.
//
//  Isolation is inherited from `PalaceWiringTestCase` (per-test singleton reset,
//  `deferInitialLoadCatalogsForTesting`, tearDown drain, disk-cache purge).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerCatalogLoadJoinTests: PalaceWiringTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog_join_tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// Zero-catalog OPDS 2.0 feed so the bundled decode does no per-account work.
    private func writeStubSnapshot() throws -> URL {
        let payload = #"{"metadata":{"title":"PP-4754 stub"},"catalogs":[],"links":[]}"#
        let url = tempDir
            .appendingPathComponent("\(BundledRegistrySnapshot.resourceName).\(BundledRegistrySnapshot.resourceExtension)")
        try payload.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Isolated defaults so `currentAccountIdentifierKey` can't resolve a real
    /// account and flip the manager onto the warm memory path.
    private func isolatedDefaults() -> UserDefaults {
        let name = "pp4754.join.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 1 + 2. Whole-set join reaches quiescence; scheduling contract

    func testColdLoad_awaitCatalogLoad_drivesOwnedChainToQuiescence() async throws {
        let snapshotURL = try writeStubSnapshot()
        let resolver = StubSnapshotResolver(snapshotURL: snapshotURL)
        let recorder = RecordingCrawlScheduler()

        let manager = makeFreshAccountsManager(
            defaults: isolatedDefaults(),
            crawlScheduler: recorder.scheduler()
        ) {
            $0.snapshotResourceResolver = resolver
        }

        // deferInitialLoadCatalogsForTesting is pinned true by the helper, so
        // init spawned nothing — the ONLY spawns are the ones this call drives.
        XCTAssertEqual(manager._ownedCrawlTaskCountForTesting, 0,
                       "precondition: opt-out construction spawns no crawl task")

        manager.loadCatalogs(completion: nil)

        // Deterministic whole-set join — no wall-clock. Grows until stable across
        // the finite first-run → crawl → fallback chain.
        await manager._awaitCatalogLoadForTesting()

        XCTAssertEqual(manager._ownedCrawlTaskCountForTesting, 0,
                       "after the join every owned crawl task must have drained (grow-until-stable reached quiescence)")

        // Scheduling contract: first-run detached .utility → crawl inheriting
        // .userInitiated → fallback GET detached .utility (the crux: the fallback
        // is now OWNED, so it appears here at all).
        let spawns = recorder.spawns
        XCTAssertGreaterThanOrEqual(spawns.count, 3,
                                    "cold offline load must spawn first-run, crawl, and the fallback GET")
        XCTAssertEqual(spawns[0], .init(priority: .utility, detached: true),
                       "first spawn is the first-run task (detached .utility)")
        XCTAssertEqual(spawns[1], .init(priority: .userInitiated, detached: false),
                       "second spawn is the fetchFromNetwork crawl (inheriting .userInitiated)")
        XCTAssertEqual(spawns[2], .init(priority: .utility, detached: true),
                       "third spawn is the wrapped fallback GET (owned detached .utility) — the previously un-drainable write channel")
    }

    // MARK: - 3. Drain completeness for the wrapped fallback GET

    func testColdLoad_cancelAndDrain_leavesOwnedSetEmpty() async throws {
        let snapshotURL = try writeStubSnapshot()
        let resolver = StubSnapshotResolver(snapshotURL: snapshotURL)
        let recorder = RecordingCrawlScheduler()

        let manager = makeFreshAccountsManager(
            defaults: isolatedDefaults(),
            crawlScheduler: recorder.scheduler()
        ) {
            $0.snapshotResourceResolver = resolver
        }

        manager.loadCatalogs(completion: nil)
        // Let the chain fully materialize (first-run → crawl → fallback) so the
        // fallback GET is actually owned when we drain — the join is the
        // deterministic barrier that guarantees it spawned.
        await manager._awaitCatalogLoadForTesting()
        // Positional (not `.contains`, which the first-run spawn's identical
        // signature would also satisfy): the 3rd spawn IS the fallback GET.
        let spawns = recorder.spawns
        XCTAssertGreaterThanOrEqual(spawns.count, 3, "sanity: first-run + crawl + fallback GET all spawned")
        XCTAssertEqual(spawns[2], .init(priority: .utility, detached: true),
                       "sanity: the 3rd spawn is the owned fallback GET")

        // The synchronous drain must leave nothing live — a fire-and-forget
        // fallback completion (the pre-fix behavior) would survive this.
        manager.cancelAndDrainBackgroundWork()
        XCTAssertEqual(manager._ownedCrawlTaskCountForTesting, 0,
                       "cancelAndDrainBackgroundWork must leave the owned set empty — the wrapped fallback GET is drained, not leaked")
    }

    // MARK: - 4. Live-drain arm: an in-flight owned task is awaited by the drain

    /// Exercises the LIVE drain arm directly (not the join-first path): a crawl
    /// task held in-flight on a cancellation-aware gate is snapshotted by
    /// `cancelAndDrainBackgroundWork`, cancelled, and awaited to completion — so
    /// the owned set is empty on return. A drain that skipped the await (or
    /// never cancelled) would leave the gated task live. The gate resumes on
    /// cancellation, so no wall-clock is involved.
    func testCancelAndDrain_awaitsInFlightGatedOwnedTask() async throws {
        let snapshotURL = try writeStubSnapshot()
        let resolver = StubSnapshotResolver(snapshotURL: snapshotURL)
        let gate = SpawnGate()

        let manager = makeFreshAccountsManager(
            defaults: isolatedDefaults(),
            crawlScheduler: gate.scheduler()
        ) {
            $0.snapshotResourceResolver = resolver
        }

        manager.loadCatalogs(completion: nil)
        // The first-run task is registered synchronously by spawnOwnedCrawlTask
        // and immediately suspends on the gate → in-flight, before doing any work.
        XCTAssertGreaterThanOrEqual(manager._ownedCrawlTaskCountForTesting, 1,
                                    "an owned crawl task must be in-flight (gated) before the drain")

        // Drain: snapshot (non-empty) → cancel (the gate resumes on cancellation)
        // → await to completion. Must return with the owned set empty.
        manager.cancelAndDrainBackgroundWork()
        XCTAssertEqual(manager._ownedCrawlTaskCountForTesting, 0,
                       "cancelAndDrainBackgroundWork must cancel + await the in-flight owned task, not return while it is still live")
    }
}

// MARK: - Test helpers

/// `BundleResourceResolving` stub handing back a tiny fixture feed.
private final class StubSnapshotResolver: BundleResourceResolving, @unchecked Sendable {
    private let snapshotURL: URL?
    init(snapshotURL: URL?) { self.snapshotURL = snapshotURL }
    func resourceURL(forName name: String, extension ext: String) -> URL? {
        guard name == BundledRegistrySnapshot.resourceName,
              ext == BundledRegistrySnapshot.resourceExtension else { return nil }
        return snapshotURL
    }
}

/// A `CrawlTaskScheduler` that suspends every spawned op on a cancellation-aware
/// gate BEFORE it runs, so a test can hold an owned task in-flight and then
/// exercise the live drain arm. The gate resumes when the surrounding task is
/// cancelled (via `withTaskCancellationHandler`), so `cancelAndDrainBackgroundWork`
/// unblocks + drains it with no wall-clock wait.
private final class SpawnGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func scheduler() -> CrawlTaskScheduler {
        // Suspend on the gate, then ALWAYS run `op` — it is the registry's
        // self-pruning wrapper (`defer { complete(token) }` around the real crawl
        // body), so skipping it on cancel would leak the token. The crawl body's
        // own `Task.isCancelled` checks make it return fast when cancelled.
        CrawlTaskScheduler(
            spawn: { [self] priority, op in
                Task(priority: priority) { await self.gate(); await op() }
            },
            spawnDetached: { [self] priority, op in
                Task.detached(priority: priority) { await self.gate(); await op() }
            }
        )
    }

    /// Suspends until `open()` is called or the surrounding task is cancelled.
    private func gate() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume(); return }
                continuations.append(c)
                lock.unlock()
            }
        } onCancel: {
            resumeAll()
        }
    }

    /// Release every gated op (and any future one). Idempotent; resumes each
    /// registered continuation exactly once.
    func open() { resumeAll() }

    private func resumeAll() {
        lock.lock()
        let pending = continuations
        continuations = []
        opened = true
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Records each crawl spawn's `(priority, detached)` and delegates to real
/// Tasks so the offline chain still runs to completion.
private final class RecordingCrawlScheduler: @unchecked Sendable {
    struct Spawn: Equatable {
        let priority: TaskPriority
        let detached: Bool
    }
    private let lock = NSLock()
    private var _spawns: [Spawn] = []
    var spawns: [Spawn] { lock.lock(); defer { lock.unlock() }; return _spawns }

    func scheduler() -> CrawlTaskScheduler {
        CrawlTaskScheduler(
            spawn: { [self] priority, op in
                record(priority, detached: false)
                return Task(priority: priority) { await op() }
            },
            spawnDetached: { [self] priority, op in
                record(priority, detached: true)
                return Task.detached(priority: priority) { await op() }
            }
        )
    }

    private func record(_ priority: TaskPriority, detached: Bool) {
        lock.lock(); _spawns.append(Spawn(priority: priority, detached: detached)); lock.unlock()
    }
}
