//
//  PerBookRegistryCrashTests.swift
//  PalaceTests
//
//  PP-5507: crashes, kills and flag changes around the per-book shelf layout.
//  After any of them each book loads as it was before or after the interrupted
//  save, and no saved position is lost. Fixture: PerBookRegistryTestCase.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookModel
import PalaceCatalog
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class PerBookRegistryCrashTests: PerBookRegistryTestCase {

    // MARK: - A crash at every step

    /// A crash at any write step of an operation leaves each book as it was
    /// before the operation or after it, including saves that change several
    /// books, and one book's position and state together.
    func testCrash_AtEveryWriteStep_LeavesEachBookBeforeOrAfter() async throws {
        let operations: [(String, (TPPBookRegistry) -> Void)] = [
            ("position", { $0.setLocation(self.location("a-9"), forIdentifier: "a") }),
            ("add", { $0.addBook(self.book("n"), location: self.location("n-1"), state: .holding) }),
            ("remove", { $0.removeBook(forIdentifier: "b") }),
            ("state", { $0.setState(.downloadNeeded, for: "c") }),
            ("bookmark", { $0.addGenericBookmark(self.location("bm")!, forIdentifier: "a") }),
            ("flush", {
                $0.setLocation(self.location("c-7"), forIdentifier: "c", persistence: .coalesced)
                $0.flushPendingPositions()
            }),
            ("three books", {
                $0.setLocationDeferringSave(self.location("a-d"), forIdentifier: "a")
                $0.setLocationDeferringSave(self.location("b-d"), forIdentifier: "b")
                $0.setState(.downloadNeeded, for: "c")
            }),
            ("position and state", {
                $0.setLocationDeferringSave(self.location("a-e"), forIdentifier: "a")
                $0.setState(.downloadNeeded, for: "a")
            })
        ]
        for (name, operation) in operations {
            try? FileManager.default.removeItem(at: root)
            try await seedMigratedShelf()
            let cleanLog = LaunchLog()
            let clean = await launch(cleanLog)
            let before = shelf(clean)
            let start = cleanLog.steps.count
            operation(clean)
            await settle(clean)
            let stepCount = cleanLog.steps.count - start
            let after = shelf(await launch())
            XCTAssertNotEqual(before, after, "\(name): premise: the operation changes the shelf")
            XCTAssertGreaterThan(stepCount, 0, "\(name): premise: the operation writes")

            for step in 0..<stepCount {
                try? FileManager.default.removeItem(at: root)
                try await seedMigratedShelf()
                let crashing = LaunchLog(crashAtStep: start + step)
                let registry = await launch(crashing)
                operation(registry)
                await settle(registry)
                XCTAssertTrue(crashing.didCrash, "\(name) step \(step): premise: the crash fired")

                let reloaded = shelf(await launch())
                assertEachBook(reloaded, before: before, after: after,
                               "\(name): crash at step \(step) (\(crashing.steps.last.map { "\($0)" } ?? "-"))")
                // A flag-off launch after the crash shows the same books.
                settings.flag = false
                let withoutFlag = shelf(await launch())
                settings.flag = true
                assertEachBook(withoutFlag, before: before, after: after,
                               "\(name): flag off after a crash at step \(step)")
            }
        }
    }

    /// A crash at any step of the migration, cleanup and swap included, leaves
    /// the old shelf, and the next launch completes the move.
    func testCrash_AtEveryMigrationStep_LeavesTheOldShelf() async throws {
        try writePrimary(RegistryShelfCorpus.versioned.json)
        settings.flag = false
        let expected = shelf(await launch())
        settings.flag = true
        try plantStaleShelfAndStaging()
        let clean = LaunchLog()
        await launch(clean)
        let stepCount = clean.steps.count
        XCTAssertTrue(clean.steps.contains(.migrationCleanup) && clean.steps.contains(.migrationSwap),
                      "premise: the clean run removes the leftover staging folder and swaps folders: \(clean.steps)")

        for step in 0..<stepCount {
            try? FileManager.default.removeItem(at: root)
            try writePrimary(RegistryShelfCorpus.versioned.json)
            try plantStaleShelfAndStaging()
            let crashing = LaunchLog(crashAtStep: step)
            let crashed = shelf(await launch(crashing))
            XCTAssertEqual(crashed, expected, "step \(step) (\(clean.steps[step])): the crashing launch shows the old shelf")
            let next = shelf(await launch())
            XCTAssertEqual(next, expected, "step \(step) (\(clean.steps[step])): the next launch shows the old shelf")
            XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "step \(step): the next launch completes the move")
            XCTAssertEqual(perBookRecords(), primaryRecords(RegistryShelfCorpus.versioned.json), "step \(step): per-book files match the old file")
        }
    }

    /// A leftover `books.migrating` from a killed migration is removed by the
    /// next one and never read as the shelf.
    func testLeftoverStagingFolder_IsIgnoredAndRemoved() async throws {
        try await seedMigratedShelf()
        let expected = shelf(await launch())
        let staging = registryDirectory.appendingPathComponent("books.migrating")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(#"{"identifier":"ghost","record":{"metadata":{"id":"ghost","title":"Ghost"},"state":"holding"},"sequence":99}"#.utf8)
            .write(to: staging.appendingPathComponent("x.record.json"))

        let trusted = shelf(await launch())
        XCTAssertEqual(trusted, expected, "a trusted launch does not read the staging folder")

        settings.flag = false
        let off = await launch()
        off.setLocation(location("a-off"), forIdentifier: "a")
        await settle(off)
        settings.flag = true
        let migrated = shelf(await launch())
        XCTAssertNil(migrated["ghost"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the next migration removes it")
    }

    // MARK: - Sequence order

    /// A later save wins over an earlier one for the same book: a position
    /// save, then a save that changes the position and state together and
    /// stops before registry.json, loads as the later save.
    func testLaterSaveWins_AfterACrashBeforeTheSingleFile() async throws {
        try await seedMigratedShelf()
        let registry = await launch(LaunchLog(crashAtFirst: .backupStaging))
        registry.setLocation(location("a-x"), forIdentifier: "a")
        await settle(registry)
        registry.setLocationDeferringSave(location("a-y"), forIdentifier: "a")
        registry.setState(.downloadNeeded, for: "a")
        await settle(registry)

        let reloaded = shelf(await launch())["a"]

        XCTAssertEqual(reloaded?.location, "a-y")
        XCTAssertEqual(reloaded?.state, .downloadNeeded)
    }

    /// A trusted launch with nothing newer than registry.json does not mark it
    /// behind, so its flush writes nothing.
    func testTrustedLaunch_WithNothingNewer_FlushWritesNothing() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        let stepsAtLoad = log.steps.count

        registry.flushPendingPositions()
        await settle(registry)

        XCTAssertEqual(log.steps.count, stepsAtLoad)
    }

    // MARK: - Kills between app events

    /// Positions saved only to position files before a kill: the next launch
    /// reads them, marks registry.json as behind, and its flush writes them,
    /// so a later flag-off launch shows them too.
    func testKillAfterPositionSave_NextLaunchFlushWritesTheSingleFile() async throws {
        try await seedMigratedShelf()
        let killed = await launch()
        killed.setLocation(location("a-kill"), forIdentifier: "a")
        await settle(killed)
        XCTAssertEqual(try singleFileLocation(of: "a"), "a-1", "premise: registry.json does not have it yet")

        let next = await launch()
        XCTAssertEqual(shelf(next)["a"]?.location, "a-kill")
        next.flushPendingPositions()
        await settle(next)

        XCTAssertEqual(try singleFileLocation(of: "a"), "a-kill")
    }

    /// The same for a reload of the loaded library without a flush in between.
    func testReloadAfterPositionSave_FlushStillWritesTheSingleFile() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.setLocation(location("a-reload"), forIdentifier: "a")
        await settle(registry)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: account) { continuation.resume() }
        }
        await settle(registry)
        registry.flushPendingPositions()
        await settle(registry)

        XCTAssertEqual(try singleFileLocation(of: "a"), "a-reload")
    }

    /// Turning the flag off keeps positions saved only to position files: the
    /// flag-off launch shows them and writes them to registry.json.
    func testFlagOffAfterKill_TakesThePositionFilesAndWritesThem() async throws {
        try await seedMigratedShelf()
        let killed = await launch()
        killed.setLocation(location("a-p"), forIdentifier: "a")
        await settle(killed)

        settings.flag = false
        let off = await launch()
        XCTAssertEqual(shelf(off)["a"]?.location, "a-p")
        XCTAssertEqual(try singleFileLocation(of: "a"), "a-p", "written so it outlives the per-book files")

        settings.flag = true
        let on = await launch()
        XCTAssertEqual(shelf(on)["a"]?.location, "a-p")
    }

    // MARK: - Sync end

    /// The sync at the end of a loans refresh writes registry.json when only
    /// position files hold a position.
    func testSyncEnd_WritesTheSingleFileWhenPositionsAreNewer() async throws {
        try await seedMigratedShelf()
        let scope = SyncingAccountScope(account)
        let feed = StaticFeed(Self.loansFeed(ids: ["a", "b", "c"]))
        let registry = await launch(scope: scope, loansFeed: feed)
        await sync(registry)
        registry.setLocation(location("a-s"), forIdentifier: "a")
        await settle(registry)
        XCTAssertNotEqual(try singleFileLocation(of: "a"), "a-s", "premise: only the position file has it")

        await sync(registry)

        XCTAssertEqual(try singleFileLocation(of: "a"), "a-s")
    }

    // MARK: - Accounts and sign-out

    /// The account-scoped registry `with(account:)` builds does not move
    /// another library's shelf.
    func testWithAccount_DoesNotMoveAnotherLibrarysShelf() async throws {
        let other = "other-\(UUID().uuidString)"
        settings.flag = false
        let seed = await launch(scope: PositionTestAccountScope(other), account: other)
        seed.addBook(book("o"), state: .holding)
        await settle(seed)
        settings.flag = true
        let registry = await launch()

        var scoped: TPPBookRegistry?
        registry.with(account: other) { scoped = $0 }
        if let scoped { await settle(scoped) }

        XCTAssertNil(perBookState(of: other), "no migration ran for the other library")
        XCTAssertEqual(scoped?.allBooks.map(\.identifier), ["o"])
    }

    /// Sign-out with the flag off still removes per-book files a flag-on launch wrote.
    func testSignOutWithFlagOff_RemovesThePerBookFiles() async throws {
        try await seedMigratedShelf()
        settings.flag = false
        let registry = await launch()

        registry.reset(account)
        await settle(registry)

        XCTAssertEqual(files().keys.sorted(), [])
    }

    /// Two libraries keep their own per-book files across a library switch.
    func testTwoAccounts_PositionsGoToTheLoadedLibrarysFiles() async throws {
        let second = "second-\(UUID().uuidString)"
        try await seedMigratedShelf()
        try await seedMigratedShelf(account: second)
        let scope = PositionTestAccountScope(account)
        let registry = await launch(scope: scope)

        scope.switchTo(second)
        try await waitUntilLoaded(registry, second)
        registry.setLocation(location("second-a-2"), forIdentifier: "\(second)-a")
        await settle(registry)
        scope.switchTo(account)
        try await waitUntilLoaded(registry, account)
        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)

        XCTAssertEqual((perBookRecords(of: second)["\(second)-a"]?["location"] as? [String: Any])?["locationString"] as? String, "second-a-2")
        XCTAssertEqual((perBookRecords()["a"]?["location"] as? [String: Any])?["locationString"] as? String, "a-2")
        XCTAssertNil(perBookRecords()["\(second)-a"])
        XCTAssertEqual(try singleFileLocation(of: "\(second)-a", account: second), "second-a-2", "the switch flushed the second library")
    }

    // MARK: - Attempts

    /// A successful move resets the try count: four flag on/off cycles in one
    /// app version each move the shelf again.
    func testMigrationAttempts_ResetOnSuccess() async throws {
        try await seedMigratedShelf()
        var verifies: [Int] = []
        for cycle in 0..<4 {
            settings.flag = false
            let off = await launch()
            off.setLocation(location("a-cycle-\(cycle)"), forIdentifier: "a")
            await settle(off)
            settings.flag = true
            let log = LaunchLog()
            let on = await launch(log)
            verifies.append(log.steps.filter { $0 == .migrationVerify }.count)
            XCTAssertEqual(shelf(on)["a"]?.location, "a-cycle-\(cycle)")
        }
        XCTAssertEqual(verifies, [1, 1, 1, 1])
    }

    // MARK: - Helpers

    private func plantStaleShelfAndStaging() throws {
        let books = registryDirectory.appendingPathComponent("books")
        let staging = registryDirectory.appendingPathComponent("books.migrating")
        for folder in [books, staging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"identifier":"stale","record":{"metadata":{"id":"stale"},"state":"holding"},"sequence":5}"#.utf8)
                .write(to: folder.appendingPathComponent("stale.record.json"))
        }
    }

    private func waitUntilLoaded(_ registry: TPPBookRegistry, _ account: String) async throws {
        for _ in 0..<500 where registry.loadedAccountID != account {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(registry.loadedAccountID, account)
        await settle(registry)
    }

    private func sync(_ registry: TPPBookRegistry) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.sync { _, _ in continuation.resume() }
        }
        await settle(registry)
    }

    private static func loansFeed(ids: [String]) -> TPPOPDSFeed {
        let entries = ids.map { id in
            """
            <entry>
              <title type="text">Book \(id)</title>
              <id>\(id)</id>
              <updated>2026-07-01T00:00:00Z</updated>
              <link href="http://example.com/\(id).epub" type="application/epub+zip" rel="http://opds-spec.org/acquisition/open-access" />
            </entry>
            """
        }
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">Loans</title>
          <id>urn:test:loans</id>
          <updated>2026-07-01T00:00:00Z</updated>
          \(entries.joined(separator: "\n"))
        </feed>
        """
        guard let parsed = TPPXML.xml(withData: Data(xml.utf8)), let feed = TPPOPDSFeed(xml: parsed) else {
            fatalError("loans fixture did not parse")
        }
        return feed
    }
}

/// A signed-in library with a loans URL, so `sync()` fetches the feed.
private final class SyncingAccountScope: AccountScopeProviding, @unchecked Sendable {
    let currentAccountID: String?
    init(_ accountID: String) { currentAccountID = accountID }
    var accountDidChangePublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func hasCredentials(forAccount accountID: String) -> Bool { true }
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? {
        URL(string: "https://per-book-sync.example.com/loans")
    }
}

private struct StaticFeed: OPDSFeedFetching, @unchecked Sendable {
    let feed: TPPOPDSFeed
    init(_ feed: TPPOPDSFeed) { self.feed = feed }
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed { feed }
}
