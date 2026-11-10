//
//  PerBookRegistryStorageTests.swift
//  PalaceTests
//
//  PP-5507: migration, flag on and off, write errors and the empty-shelf rule
//  of the per-book shelf layout. Fixture: PerBookRegistryTestCase.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry
import PalaceFeatureFlags

@MainActor
final class PerBookRegistryStorageTests: PerBookRegistryTestCase {

    // MARK: - Migration

    /// Every corpus shelf moves without loss: the per-book files hold every
    /// record of the old file, and a later launch shows the same shelf.
    func testMigration_OlderShelfFiles_MoveToPerBookFilesWithoutLoss() async throws {
        for corpus in RegistryShelfCorpus.all {
            try? FileManager.default.removeItem(at: root)
            try writePrimary(corpus.json)
            settings.flag = false
            let offStarted = Date()
            let expected = shelf(await launch())
            let offMilliseconds = Int(Date().timeIntervalSince(offStarted) * 1000)
            XCTAssertFalse(expected.isEmpty, "\(corpus.name): premise: the corpus loads")

            settings.flag = true
            let migrating = LaunchLog()
            let migrationStarted = Date()
            let migrated = shelf(await launch(migrating))
            // Reported, not asserted: wall time depends on machine load.
            print("per-book migration \(corpus.name): launch \(Int(Date().timeIntervalSince(migrationStarted) * 1000)) ms with migration, \(offMilliseconds) ms flag off")

            XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "\(corpus.name): migration verified")
            XCTAssertTrue(migrating.steps.contains(.migrationSwap), "\(corpus.name): the per-book files were put in place")
            XCTAssertEqual(perBookRecords(), primaryRecords(corpus.json), "\(corpus.name): per-book files equal the old file record for record")
            XCTAssertEqual(migrated, expected, "\(corpus.name): the migrating launch shows the old shelf")
            let relaunched = LaunchLog()
            let launched1 = shelf(await launch(relaunched))
            XCTAssertEqual(launched1, expected, "\(corpus.name): the next launch reads the same shelf from the per-book files")
            XCTAssertFalse(relaunched.steps.contains(.migrationStaging), "\(corpus.name): a verified shelf is not moved again")
        }
    }

    /// A read-back difference keeps the old file in use, removes the staged
    /// files, and retries on the next launch, three times per app version.
    func testMigration_VerifyMismatch_FallsBackAndRetriesThreeTimesPerVersion() async throws {
        try writePrimary(RegistryShelfCorpus.versioned.json)
        let primaryBefore = try Data(contentsOf: primaryURL)
        settings.flag = false
        let expected = shelf(await launch())
        settings.flag = true

        let alterStagedRecord: @Sendable (URL) -> Void = { migrating in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: migrating.path)) ?? []
            guard let name = names.sorted().first(where: { $0.hasSuffix(".record.json") }) else { return }
            let url = migrating.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var record = object["record"] as? [String: Any] else { return }
            record["state"] = "unregistered"
            object["record"] = record
            try? JSONSerialization.data(withJSONObject: object).write(to: url)
        }

        var verifyCounts: [Int] = []
        for _ in 0..<4 {
            let log = LaunchLog(beforeVerify: alterStagedRecord)
            let registry = await launch(log)
            verifyCounts.append(log.steps.filter { $0 == .migrationVerify }.count)
            XCTAssertEqual(shelf(registry), expected, "a failed migration shows the old file's shelf")
            XCTAssertFalse(FileManager.default.fileExists(atPath: booksDirectory.path), "no per-book files are put in place")
            XCTAssertFalse(FileManager.default.fileExists(atPath: registryDirectory.appendingPathComponent("books.migrating").path),
                           "the staged files are removed")
            XCTAssertEqual(try Data(contentsOf: primaryURL), primaryBefore, "the old file is not rewritten by a migration")
        }
        XCTAssertEqual(verifyCounts, [1, 1, 1, 0], "three tries for one app version, then none")

        let stillOld = LaunchLog()
        let registry = await launch(stillOld)
        registry.setLocation(location("after-fallback"), forIdentifier: "urn:isbn:9780000000004")
        await settle(registry)
        XCTAssertEqual(stillOld.steps.suffix(1), [.primary], "positions still go to the old file")

        settings.version = "4.0.1 (601)"
        let retried = LaunchLog()
        await launch(retried)
        XCTAssertEqual(retried.steps.filter { $0 == .migrationVerify }.count, 1, "a new app version gets a new try")
        XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "the untampered try succeeds")
    }

    /// A launch with the flag on after a launch with it off reads the newer old
    /// file, not the per-book files the flag-off launch did not update.
    func testFlagOnAfterFlagOffLaunch_UsesTheNewerSingleFile() async throws {
        try await seedMigratedShelf()
        settings.flag = false
        let off = await launch()
        off.setLocation(location("a-off"), forIdentifier: "a")
        off.removeBook(forIdentifier: "c")
        await settle(off)
        let expected = shelf(off)

        settings.flag = true
        let launched2 = shelf(await launch())
        XCTAssertEqual(launched2, expected)
        let launched3 = shelf(await launch())
        XCTAssertEqual(launched3, expected, "and again once the shelf moved anew")
    }

    // MARK: - Flag off

    /// With the flag off nothing new is written: the same write steps as a
    /// registry built without the flag, equal registry files, and per-book files
    /// from an earlier flag-on launch left byte for byte.
    ///
    /// Not a byte comparison of `registry.json` between two registries: Swift
    /// seeds dictionary order per instance, so two instances order records and
    /// keys differently. Records are compared by identifier.
    func testFlagOff_WritesWhatTheRegistryWroteBefore() async throws {
        try await seedMigratedShelf()
        let perBookBefore = files().filter { $0.key.hasPrefix("books") }
        XCTAssertFalse(perBookBefore.isEmpty, "premise: per-book files exist")

        let baselineRoot = root.appendingPathComponent("baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baselineRoot.appendingPathComponent(account).appendingPathComponent("registry"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: primaryURL,
                                         to: baselineRoot.appendingPathComponent(account).appendingPathComponent("registry/registry.json"))
        let baselineLog = LaunchLog()
        let baseline = TPPBookRegistry(
            accountScope: PositionTestAccountScope(account),
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { NoContentDownloadService() },
                loansFeedFetcher: { UnreachableLoansFeed() },
                sideloadedIdentifiers: { [] },
                registryDirectory: { baselineRoot.appendingPathComponent($0, isDirectory: true) },
                onAvailabilityChange: { _, _ in },
                beforeRegistryWrite: { try baselineLog.beforeWrite($0, $1) },
                positionClock: { [clock] in clock.now }
            )
        )
        launches.append(baseline)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            baseline.load(account: account) { continuation.resume() }
        }
        settings.flag = false
        let offLog = LaunchLog()
        let off = await launch(offLog)

        let operations: [(String, (TPPBookRegistry) -> Void)] = [
            ("add", { $0.addBook(self.book("d"), state: .holding) }),
            ("position", { $0.setLocation(self.location("a-2"), forIdentifier: "a") }),
            ("coalesced", { $0.setLocation(self.location("b-2"), forIdentifier: "b", persistence: .coalesced) }),
            ("flush", { $0.flushPendingPositions() }),
            ("state", { $0.setState(.downloadNeeded, for: "c") }),
            ("remove", { $0.removeBook(forIdentifier: "d") })
        ]
        for (name, operation) in operations {
            operation(baseline)
            operation(off)
            await settle(baseline)
            await settle(off)
            XCTAssertEqual(offLog.steps, baselineLog.steps, "\(name): same write steps as the registry built without the flag")
            let baselineFile = try String(decoding: Data(contentsOf:
                baselineRoot.appendingPathComponent(account).appendingPathComponent("registry/registry.json")), as: UTF8.self)
            let offFile = try String(decoding: Data(contentsOf: primaryURL), as: UTF8.self)
            XCTAssertEqual(primaryRecords(offFile), primaryRecords(baselineFile), "\(name): same registry.json records")
            XCTAssertEqual(schemaVersion(offFile), schemaVersion(baselineFile), "\(name): same schema version")
        }
        XCTAssertFalse(offLog.steps.contains { ![.backupStaging, .backupReplace, .primary].contains($0) },
                       "no per-book step runs with the flag off")
        XCTAssertEqual(files().filter { $0.key.hasPrefix("books") }, perBookBefore, "per-book files untouched")
    }

    // MARK: - Flag on

    /// One position save writes one small position file and nothing else.
    func testFlagOn_PositionSave_WritesOnePositionFileOnly() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        let before = files()
        let stepsBefore = log.steps.count

        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)

        XCTAssertEqual(Array(log.steps.dropFirst(stepsBefore)), [.bookPosition])
        let after = files()
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        XCTAssertEqual(changed.count, 1, "changed: \(changed.sorted())")
        let path = try XCTUnwrap(changed.first)
        XCTAssertTrue(path.hasPrefix("books/") && path.hasSuffix(".position.json"), path)
        XCTAssertLessThan(after[path]?.count ?? .max, 512, "a position file is small")
        let launched4 = shelf(await launch())
        XCTAssertEqual(launched4["a"]?.location, "a-2", "the next launch reads the position")
    }

    /// The single file is still written at the app events: here the flush that
    /// background, terminate and a library switch run.
    func testFlagOn_Flush_WritesTheSingleFileWithTheNewPositions() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.setLocation(location("a-3"), forIdentifier: "a")
        await settle(registry)

        registry.flushPendingPositions()
        await settle(registry)

        XCTAssertEqual(try singleFileLocation(of: "a"), "a-3")
    }

    /// The flag is read at each load: turned off for a reload, positions go
    /// back to the old file in the same launch.
    func testFlagTurnedOffAtReload_PositionsGoToTheSingleFile() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)

        settings.flag = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: account) { continuation.resume() }
        }
        await settle(registry)
        registry.setLocation(location("a-off"), forIdentifier: "a")
        await settle(registry)

        XCTAssertEqual(log.steps.last, .primary)
        XCTAssertEqual(try singleFileLocation(of: "a"), "a-off")
    }

    /// After sign-out the account writes no per-book files until it loads again.
    func testSignOut_StopsPerBookWritesUntilTheNextLoad() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.reset(account)
        await settle(registry)

        registry.addBook(book("after"), state: .holding)
        await settle(registry)

        XCTAssertFalse(FileManager.default.fileExists(atPath: booksDirectory.path))
        XCTAssertNil(perBookState())
    }

    /// Sign-out removes the per-book files with the old file.
    func testSignOut_RemovesThePerBookFiles() async throws {
        try await seedMigratedShelf()
        let registry = await launch()

        registry.reset(account)
        await settle(registry)

        XCTAssertEqual(files().keys.sorted(), [], "nothing of the shelf is left on disk")
    }

    // MARK: - Write errors

    /// A failed position file write (a full disk) keeps the position: it goes
    /// to the old file, and later positions do too.
    func testWriteError_OnPositionFile_FallsBackToTheSingleFile() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog(failOnce: .bookPosition)
        let registry = await launch(log)

        registry.setLocation(location("a-full"), forIdentifier: "a")
        await settle(registry)
        registry.setLocation(location("b-later"), forIdentifier: "b")
        await settle(registry)

        XCTAssertEqual(log.steps.last, .primary, "after a failure positions go to the old file")
        let reloaded = shelf(await launch())
        XCTAssertEqual(reloaded["a"]?.location, "a-full")
        XCTAssertEqual(reloaded["b"]?.location, "b-later")
    }

    /// A failed record file write keeps the book: the old file is written, and
    /// the next launch moves the shelf again.
    func testWriteError_OnRecordFile_KeepsTheBook() async throws {
        try await seedMigratedShelf()
        let registry = await launch(LaunchLog(failOnce: .bookRecord))

        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        registry.setLocation(location("x-1"), forIdentifier: "x")
        await settle(registry)

        let reloaded = shelf(await launch())
        XCTAssertEqual(reloaded["x"]?.location, "x-1")
        XCTAssertEqual(Set(reloaded.keys), ["a", "b", "c", "x"])
        XCTAssertEqual(perBookState()?["verified"] as? Bool, true)
    }

    /// Per-book files that failed to update are not trusted: the next launch
    /// moves the shelf again from the old file.
    func testWriteError_OnRecordFile_NextLaunchMovesTheShelfAgain() async throws {
        try await seedMigratedShelf()
        let registry = await launch(LaunchLog(failOnce: .bookRecord))
        registry.addBook(book("x"), state: .holding)
        await settle(registry)

        let next = LaunchLog()
        let reloaded = shelf(await launch(next))

        XCTAssertTrue(next.steps.contains(.migrationVerify), "the shelf is moved again")
        XCTAssertEqual(Set(reloaded.keys), ["a", "b", "c", "x"])
    }

    /// After a failed position file write, the flush the app events run still
    /// writes the position to the old file.
    func testWriteError_OnPositionFile_FlushWritesItToTheSingleFile() async throws {
        try await seedMigratedShelf()
        let registry = await launch(LaunchLog(failOnce: .bookPosition))
        registry.setLocation(location("a-full"), forIdentifier: "a")
        await settle(registry)

        registry.flushPendingPositions()
        await settle(registry)

        XCTAssertEqual(try singleFileLocation(of: "a"), "a-full")
    }

    /// A shelf save keeps the per-book files trusted, so the next launch reads
    /// them without moving the shelf again.
    func testShelfSave_KeepsThePerBookFilesTrusted() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.addBook(book("x"), location: location("x-1"), state: .holding)
        await settle(registry)

        let next = LaunchLog()
        let reloaded = shelf(await launch(next))

        XCTAssertFalse(next.steps.contains(.migrationStaging), "no second move")
        XCTAssertEqual(reloaded["x"]?.location, "x-1")
        XCTAssertNotNil(perBookRecords()["x"], "the new book has its own files")
    }

    // MARK: - Empty never replaces non-empty

    /// An empty save, async or blocking, is refused while per-book files hold a
    /// book even when `registry.json` and `.bak` hold none.
    func testEmptySave_OverPerBookBooks_IsRefusedWhenTheSingleFileIsEmpty() async throws {
        try writePrimary(#"{"schemaVersion":1,"records":[]}"#)
        await launch()
        XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "premise: the empty shelf moved")
        // A crash after the book's record file and before registry.json: the
        // per-book files hold a book that registry.json and `.bak` do not.
        let crashing = await launch(LaunchLog(crashAtFirst: .backupStaging))
        crashing.addBook(book("solo"), location: location("solo-1"), state: .holding)
        await settle(crashing)
        let registry = await launch()
        XCTAssertEqual(Set(shelf(registry).keys), ["solo"], "premise: the per-book files hold the shelf")

        registry.removeBook(forIdentifier: "solo")
        await settle(registry)
        registry.saveSync()
        await settle(registry)

        XCTAssertNotNil(perBookRecords()["solo"], "the book's files are kept")
        let reloaded = shelf(await launch())
        XCTAssertEqual(reloaded["solo"]?.location, "solo-1")
    }


    /// An empty save without server authority leaves the per-book files, as it
    /// leaves the old file.
    func testEmptyShelf_WithoutServerAuthority_KeepsPerBookFiles() async throws {
        try await seedMigratedShelf()
        let registry = await launch()

        for id in ["a", "b", "c"] { registry.removeBook(forIdentifier: id) }
        await settle(registry)

        XCTAssertFalse(perBookRecords().isEmpty, "the last book's files are kept")
        let launched7 = shelf(await launch())
        XCTAssertFalse(launched7.isEmpty, "the next launch does not show an empty shelf")
    }

    /// A valid empty old file does not replace non-empty per-book files.
    func testMigration_EmptyOldFile_DoesNotReplaceNonEmptyPerBookFiles() async throws {
        try await seedMigratedShelf()
        let perBookBefore = files().filter { $0.key.hasPrefix("books/") }
        try writePrimary(#"{"schemaVersion":1,"records":[]}"#)

        await launch()

        XCTAssertEqual(files().filter { $0.key.hasPrefix("books/") }, perBookBefore)
    }

    /// Missing per-book files never hide books the old file holds.
    func testTrustedLoad_MissingPerBookFiles_KeepsTheOldFileBooks() async throws {
        try await seedMigratedShelf()
        let expected = shelf(await launch())
        try FileManager.default.removeItem(at: booksDirectory)

        let launched8 = shelf(await launch())
        XCTAssertEqual(launched8, expected)
    }

    // MARK: - Flag wiring

    /// The production registry reads the Remote Config flag, which is off when
    /// Remote Config has no value, and off when no flag source is passed.
    func testProductionWiring_ReadsTheRemoteFlag_DefaultOff() {
        let flags = MockFeatureFlagProvider()
        let dependencies = RegistryExternalDependencies.production(featureFlags: flags)
        XCTAssertFalse(dependencies.perBookStorageEnabled(), "no Remote Config value: off")

        flags.rawFlagOverrides[.perBookRegistryStorageEnabled] = true
        XCTAssertTrue(dependencies.perBookStorageEnabled(), "read at call time, so the next load sees a fetched value")
        XCTAssertFalse(RegistryExternalDependencies.production().perBookStorageEnabled(), "no flag source: off")
    }
}
