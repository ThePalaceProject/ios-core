//  AccountRegistryLoaderSeamTests.swift
//
//  Pins `AccountRegistryLoader` (catalog load, background crawl and drain,
//  extracted from AccountsManager) built directly with spies, a recording
//  `CrawlTaskScheduler` and stub cache/network: one detached `.utility` spawn for
//  the initial load, a prompt empty-set drain, and `carveSlimFeed` purity. The
//  wider load pipeline stays covered by the AccountsManager suites.

import XCTest
import PalaceCatalog
import PalaceBookModel
import PalacePreferences
@testable import Palace

@MainActor
final class AccountRegistryLoaderSeamTests: XCTestCase {

    /// `spawnInitialBackgroundLoad()` schedules exactly one DETACHED `.utility` crawl task
    /// (the init background-load arm). Regression caught: a change that changes detachedness/QoS or
    /// spawns zero/many tasks flips the recorded spawn list.
    func testSpawnInitialBackgroundLoad_schedulesOneDetachedUtilityTask() {
        let recorder = SchedulerRecorder()
        let loader = makeLoader(scheduler: recorder.scheduler)

        loader.spawnInitialBackgroundLoad()

        XCTAssertEqual(recorder.spawns.count, 1, "exactly one initial background-load task")
        XCTAssertEqual(recorder.spawns.first?.detached, true, "the init load arm is detached")
        XCTAssertEqual(recorder.spawns.first?.priority, .utility, "the init load arm runs at .utility")
    }

    /// `cancelAndDrainBackgroundWork` with no owned tasks pumps the main run loop briefly
    /// then RETURNS — it must never hang the test boundary (bounded pump). Regression caught: a
    /// regression that blocks main / drops the bound would time out.
    func testCancelAndDrain_withNoTasks_returnsPromptly() {
        let recorder = SchedulerRecorder()
        let loader = makeLoader(scheduler: recorder.scheduler)

        let start = Date()
        loader.cancelAndDrainBackgroundWork(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                          "empty-set drain must return well within the bound, never hang")
    }

    /// `carveSlimFeed` keeps only the `catalogs` entries whose `metadata.id` is in
    /// `keepUUIDs`, and returns nil when none match. Regression caught: dropping the filter or the
    /// empty-guard.
    func testCarveSlimFeed_keepsOnlyMatchingUUIDs() throws {
        let full = """
        {"catalogs":[
          {"metadata":{"id":"A","title":"a"}},
          {"metadata":{"id":"B","title":"b"}}
        ]}
        """.data(using: .utf8)!

        let carved = try XCTUnwrap(AccountRegistryLoader.carveSlimFeed(fromFullCatalogData: full, keepUUIDs: ["A"]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: carved) as? [String: Any])
        let catalogs = try XCTUnwrap(root["catalogs"] as? [[String: Any]])
        XCTAssertEqual(catalogs.count, 1)
        XCTAssertEqual((catalogs.first?["metadata"] as? [String: Any])?["id"] as? String, "A")

        XCTAssertNil(AccountRegistryLoader.carveSlimFeed(fromFullCatalogData: full, keepUUIDs: ["Z"]),
                     "no matching uuid → nil")
        XCTAssertNil(AccountRegistryLoader.carveSlimFeed(fromFullCatalogData: full, keepUUIDs: []),
                     "empty keep set → nil")
    }

    // MARK: - Helper

    private func makeLoader(scheduler: CrawlTaskScheduler) -> AccountRegistryLoader {
        AccountRegistryLoader(
            registryCache: StubRegistryCache(),
            registryStore: AccountRegistryStore(),
            crawlScheduler: scheduler,
            settings: TPPSettings(),
            imageCache: MockImageCache(),
            accountStateStore: AccountStateStore(),
            ageCheck: TPPAgeCheck(ageCheckChoiceStorage: TPPSettings()),
            networkExecutorProvider: { StubNetworking() },
            currentAccountProvider: { nil },
            currentAccountIdProvider: { nil },
            accountsForKeyProvider: { _ in [] },
            accountProvider: { _ in nil },
            currentUserAccountProvider: { nil },
            driveCurrentAccountAuthDoc: {},
            fetchAuthDocumentWithStateMachine: { _, completion in completion(true) },
            currentLibraryAccountProvider: { nil }
        )
    }
}

// MARK: - Test doubles

/// Records each crawl-task spawn (detachedness + priority) and returns a trivial completed
/// Task WITHOUT running the operation — so `spawnInitialBackgroundLoad`'s scheduling is
/// observable with no live network / crawl firing.
fileprivate final class SchedulerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _spawns: [(detached: Bool, priority: TaskPriority)] = []
    var spawns: [(detached: Bool, priority: TaskPriority)] {
        lock.lock(); defer { lock.unlock() }; return _spawns
    }
    private func record(_ detached: Bool, _ priority: TaskPriority) {
        lock.lock(); _spawns.append((detached, priority)); lock.unlock()
    }
    lazy var scheduler = CrawlTaskScheduler(
        spawn: { [self] priority, _ in record(false, priority); return Task {} },
        spawnDetached: { [self] priority, _ in record(true, priority); return Task {} }
    )
}

/// Inert `AccountRegistryCaching` — the loader construction/scheduling/drain tests never
/// exercise the disk path. `@unchecked Sendable`: no mutable state.
fileprivate final class StubRegistryCache: AccountRegistryCaching, @unchecked Sendable {
    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {}
    func readCatalogData(hash: String) -> Data? { nil }
    func hasFreshCatalogData(hash: String) -> Bool { false }
    func isCatalogStale(hash: String) -> Bool { false }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() {}
}

/// Inert `AccountNetworking` — the drain's `cancelNonEssentialTasks` is a no-op here.
fileprivate final class StubNetworking: AccountNetworking, @unchecked Sendable {
    func cancelNonEssentialTasks() {}
    func clearCache() {}
    func GET(_ reqURL: URL, useTokenIfAvailable: Bool) async throws -> (Data, URLResponse?) {
        (Data(), nil)
    }
}
