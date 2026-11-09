//
//  PerBookRegistryStorageTests.swift
//  PalaceTests
//
//  PP-5507: the per-book shelf layout behind `per_book_registry_storage`. Each
//  "launch" is a new registry over the same directory; a crash is a write step
//  that throws and makes every later write of that launch throw. Layout and
//  rules: docs/architecture/per-book-registry-storage.md.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry
import PalaceFeatureFlags

@MainActor
final class PerBookRegistryStorageTests: XCTestCase {

    // MARK: - Doubles

    /// The write steps of one launch. Can end the launch at a step, fail one
    /// step once, or edit `books.migrating` before it is read back.
    final class LaunchLog: @unchecked Sendable {
        struct Crash: Error {}
        struct DiskFull: Error {}

        private let lock = NSLock()
        private var _steps: [RegistryWriteStep] = []
        private var crashIndex: Int?
        private var crashed = false
        private var failOnce: RegistryWriteStep?
        private var verifyHook: (@Sendable (URL) -> Void)?

        init(crashAtStep index: Int? = nil, failOnce step: RegistryWriteStep? = nil,
             beforeVerify hook: (@Sendable (URL) -> Void)? = nil) {
            crashIndex = index
            failOnce = step
            verifyHook = hook
        }

        var steps: [RegistryWriteStep] { lock.withLock { _steps } }
        var didCrash: Bool { lock.withLock { crashed } }

        func beforeWrite(_ step: RegistryWriteStep, _ url: URL) throws {
            lock.lock()
            if crashed { lock.unlock(); throw Crash() }
            let index = _steps.count
            _steps.append(step)
            if index == crashIndex { crashed = true; lock.unlock(); throw Crash() }
            if failOnce == step { failOnce = nil; lock.unlock(); throw DiskFull() }
            let hook = step == .migrationVerify ? verifyHook : nil
            lock.unlock()
            hook?(url)
        }
    }

    /// Flag and app version as the next launch reads them.
    final class LaunchSettings: @unchecked Sendable {
        private let lock = NSLock()
        private var _flag = true
        private var _version = "4.0.0 (600)"
        var flag: Bool {
            get { lock.withLock { _flag } }
            set { lock.withLock { _flag = newValue } }
        }
        var version: String {
            get { lock.withLock { _version } }
            set { lock.withLock { _version = newValue } }
        }
    }

    /// What a patron sees of one book.
    struct ShelfEntry: Equatable, CustomStringConvertible {
        let title: String
        let state: TPPBookState
        let location: String?
        let genericBookmarks: Int
        let readiumBookmarks: Int
        var description: String {
            "\(title)|\(state.stringValue())|\(location ?? "-")|g\(genericBookmarks)|r\(readiumBookmarks)"
        }
    }

    // MARK: - Fixture

    private var root: URL!
    private var settings: LaunchSettings!
    private var launches: [TPPBookRegistry] = []
    private let clock = PositionTestClock()
    private let account = "perbook-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerBookRegistryStorageTests-\(UUID().uuidString)", isDirectory: true)
        settings = LaunchSettings()
    }

    override func tearDown() {
        launches.removeAll()
        try? FileManager.default.removeItem(at: root)
        root = nil
        settings = nil
        super.tearDown()
    }

    private var registryDirectory: URL { root.appendingPathComponent(account).appendingPathComponent("registry") }
    private var primaryURL: URL { registryDirectory.appendingPathComponent("registry.json") }
    private var booksDirectory: URL { registryDirectory.appendingPathComponent("books") }
    private var stateURL: URL { registryDirectory.appendingPathComponent("books-state.json") }

    private func dependencies(_ log: LaunchLog) -> RegistryExternalDependencies {
        let root = self.root!
        let settings = self.settings!
        let clock = self.clock
        return RegistryExternalDependencies(
            downloadService: { NoContentDownloadService() },
            loansFeedFetcher: { UnreachableLoansFeed() },
            sideloadedIdentifiers: { [] },
            registryDirectory: { root.appendingPathComponent($0, isDirectory: true) },
            onAvailabilityChange: { _, _ in },
            beforeRegistryWrite: { try log.beforeWrite($0, $1) },
            positionClock: { clock.now },
            perBookStorageEnabled: { settings.flag },
            appVersion: { settings.version }
        )
    }

    /// A new registry over the same files, loaded: an app launch.
    @discardableResult
    private func launch(_ log: LaunchLog = LaunchLog()) async -> TPPBookRegistry {
        let registry = TPPBookRegistry(
            accountScope: PositionTestAccountScope(account),
            imageLoader: MockImageLoader(),
            dependencies: dependencies(log)
        )
        launches.append(registry)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: account) { continuation.resume() }
        }
        await settle(registry)
        return registry
    }

    /// Waits for queued saves, including a fallback save the disk queue hands
    /// back to the main queue.
    private func settle(_ registry: TPPBookRegistry) async {
        await registry._awaitPendingPersistenceForTesting()
        await drainMainQueueAsync()
        await registry._awaitPendingPersistenceForTesting()
    }

    private func shelf(_ registry: TPPBookRegistry) -> [String: ShelfEntry] {
        var result: [String: ShelfEntry] = [:]
        for book in registry.allBooks {
            result[book.identifier] = ShelfEntry(
                title: book.title,
                state: registry.state(for: book.identifier),
                location: registry.location(forIdentifier: book.identifier)?.locationString,
                genericBookmarks: registry.genericBookmarksForIdentifier(book.identifier).count,
                readiumBookmarks: registry.readiumBookmarks(forIdentifier: book.identifier).count
            )
        }
        return result
    }

    private func writePrimary(_ json: String) throws {
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: primaryURL)
    }

    private func book(_ id: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: id, title: "Book \(id)", distributorType: .EpubZip)
    }

    private func location(_ value: String) -> TPPBookLocation? {
        TPPBookLocation(locationString: value, renderer: "test-renderer")
    }

    /// Every file under the account's registry folder, by relative path.
    private func files() -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: registryDirectory, includingPropertiesForKeys: nil) else { return result }
        let prefix = registryDirectory.resolvingSymlinksInPath().path + "/"
        for case let url as URL in enumerator {
            guard let data = try? Data(contentsOf: url) else { continue }
            result[url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")] = data
        }
        return result
    }

    private func perBookState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The per-book files merged back into whole records, by identifier.
    private func perBookRecords() -> [String: NSDictionary] {
        var records: [String: [String: Any]] = [:]
        var positions: [String: Any?] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? []
        for name in names {
            guard let data = try? Data(contentsOf: booksDirectory.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["identifier"] as? String else { continue }
            if name.hasSuffix(".record.json") { records[id] = object["record"] as? [String: Any] }
            if name.hasSuffix(".position.json") { positions[id] = .some(object["location"]) }
        }
        var merged: [String: NSDictionary] = [:]
        for (id, var record) in records {
            if case .some(.some(let value)) = positions[id] { record["location"] = value }
            merged[id] = record as NSDictionary
        }
        return merged
    }

    /// The records of a registry file by identifier, last one winning, as load reads them.
    private func primaryRecords(_ json: String) -> [String: NSDictionary] {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var result: [String: NSDictionary] = [:]
        for record in object["records"] as! [[String: Any]] {
            guard let id = (record["metadata"] as? [String: Any])?["id"] as? String else { continue }
            result[id] = record as NSDictionary
        }
        return result
    }

    /// The location string `registry.json` holds for a book.
    private func singleFileLocation(of identifier: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: primaryURL)) as? [String: Any]
        let records = object?["records"] as? [[String: Any]] ?? []
        return records.first { ($0["metadata"] as? [String: Any])?["id"] as? String == identifier }
            .flatMap { ($0["location"] as? [String: Any])?["locationString"] as? String }
    }

    private func schemaVersion(_ json: String) -> Int? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["schemaVersion"] as? Int
    }

    /// A migrated three-book shelf with positions, written by an earlier launch.
    private func seedMigratedShelf() async throws {
        settings.flag = false
        let first = await launch()
        for id in ["a", "b", "c"] { first.addBook(book(id), state: .holding) }
        await settle(first)
        first.setLocation(location("a-1"), forIdentifier: "a")
        first.setLocation(location("b-1"), forIdentifier: "b")
        await settle(first)
        settings.flag = true
        await launch()
        XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "premise: the seeded shelf moved to the per-book layout")
    }

    // MARK: - Migration

    /// Every corpus shelf moves without loss: the per-book files hold every
    /// record of the old file, and a later launch shows the same shelf.
    func testMigration_OlderShelfFiles_MoveToPerBookFilesWithoutLoss() async throws {
        for corpus in RegistryShelfCorpus.all {
            try? FileManager.default.removeItem(at: root)
            try writePrimary(corpus.json)
            settings.flag = false
            let expected = shelf(await launch())
            XCTAssertFalse(expected.isEmpty, "\(corpus.name): premise: the corpus loads")

            settings.flag = true
            let migrating = LaunchLog()
            let migrated = shelf(await launch(migrating))

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

    // MARK: - Crashes and write errors

    /// A crash at any write step of an operation leaves a shelf that loads and
    /// equals the shelf before the operation or after it.
    func testCrash_AtEveryWriteStep_LeavesTheShelfBeforeOrAfter() async throws {
        let operations: [(String, (TPPBookRegistry) -> Void)] = [
            ("position", { $0.setLocation(self.location("a-9"), forIdentifier: "a") }),
            ("add", { $0.addBook(self.book("n"), location: self.location("n-1"), state: .holding) }),
            ("remove", { $0.removeBook(forIdentifier: "b") }),
            ("state", { $0.setState(.downloadNeeded, for: "c") }),
            ("bookmark", { $0.addGenericBookmark(self.location("bm")!, forIdentifier: "a") }),
            ("flush", {
                $0.setLocation(self.location("c-7"), forIdentifier: "c", persistence: .coalesced)
                $0.flushPendingPositions()
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
                XCTAssertTrue(reloaded == before || reloaded == after,
                              "\(name): crash at step \(step) (\(crashing.steps.last.map { "\($0)" } ?? "-")) left \(reloaded.sorted { $0.key < $1.key }), before \(before.sorted { $0.key < $1.key }), after \(after.sorted { $0.key < $1.key })")
            }
        }
    }

    /// A crash at any step of the migration leaves the old shelf loadable.
    func testCrash_AtEveryMigrationStep_LeavesTheOldShelf() async throws {
        try writePrimary(RegistryShelfCorpus.versioned.json)
        settings.flag = false
        let expected = shelf(await launch())
        settings.flag = true
        let clean = LaunchLog()
        await launch(clean)
        let stepCount = clean.steps.count
        XCTAssertGreaterThan(stepCount, 3, "premise: the migration writes several steps")

        for step in 0..<stepCount {
            try? FileManager.default.removeItem(at: root)
            try writePrimary(RegistryShelfCorpus.versioned.json)
            let crashing = LaunchLog(crashAtStep: step)
            let launched5 = shelf(await launch(crashing))
            XCTAssertEqual(launched5, expected, "step \(step): the crashing launch shows the old shelf")
            let launched6 = shelf(await launch())
            XCTAssertEqual(launched6, expected, "step \(step): the next launch shows the old shelf")
            XCTAssertEqual(perBookState()?["verified"] as? Bool, true, "step \(step): the next launch completes the move")
        }
    }

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
        settings.flag = false
        let first = await launch()
        first.addBook(book("solo"), location: location("solo-1"), state: .holding)
        await settle(first)
        settings.flag = true
        await launch()
        let empty = Data(#"{"schemaVersion":1,"records":[]}"#.utf8)
        try empty.write(to: primaryURL)
        try? FileManager.default.removeItem(at: primaryURL.appendingPathExtension("bak"))
        let files = PerBookRegistryFiles(registryURL: primaryURL) { _, _ in }
        try files.recordTrust(registryData: empty, appVersion: settings.version)
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
