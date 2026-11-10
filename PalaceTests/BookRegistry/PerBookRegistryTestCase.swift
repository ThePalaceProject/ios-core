//
//  PerBookRegistryTestCase.swift
//  PalaceTests
//
//  PP-5507: shared fixture for the per-book shelf layout tests. Each "launch"
//  is a new registry over the same directory; a crash is a write step that
//  throws and makes every later write of that launch throw. Layout and rules:
//  docs/architecture/per-book-registry-storage.md.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceCatalog
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
class PerBookRegistryTestCase: XCTestCase {

    // MARK: - Doubles

    /// The write steps of one launch. Can end the launch at a step, fail one
    /// step once, or edit `books.migrating` before it is read back.
    final class LaunchLog: @unchecked Sendable {
        struct Crash: Error {}
        struct DiskFull: Error {}

        private let lock = NSLock()
        private var _steps: [RegistryWriteStep] = []
        private var crashIndex: Int?
        private var crashAtStep: RegistryWriteStep?
        private var crashOccurrence = 1
        private var crashed = false
        private var failOnce: RegistryWriteStep?
        private var verifyHook: (@Sendable (URL) -> Void)?

        /// - Parameter occurrence: with `crashAtFirst`, which occurrence of that step ends the launch.
        init(crashAtStep index: Int? = nil, crashAtFirst kind: RegistryWriteStep? = nil, occurrence: Int = 1,
             failOnce step: RegistryWriteStep? = nil, beforeVerify hook: (@Sendable (URL) -> Void)? = nil) {
            crashIndex = index
            crashAtStep = kind
            crashOccurrence = occurrence
            failOnce = step
            verifyHook = hook
        }

        var steps: [RegistryWriteStep] { lock.withLock { _steps } }

        /// Ends the launch at the write step `offset` steps from now.
        func armCrash(afterSteps offset: Int) {
            lock.withLock { crashIndex = _steps.count + offset }
        }
        var didCrash: Bool { lock.withLock { crashed } }

        func beforeWrite(_ step: RegistryWriteStep, _ url: URL) throws {
            lock.lock()
            if crashed { lock.unlock(); throw Crash() }
            let index = _steps.count
            _steps.append(step)
            let isCrashStep = step == crashAtStep && _steps.filter { $0 == step }.count == crashOccurrence
            if index == crashIndex || isCrashStep { crashed = true; lock.unlock(); throw Crash() }
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

    /// Runs a block once, at the next per-book save's sequence allocation.
    final class SequenceHook: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: (() -> Void)?
        private var _fired = false
        var fired: Bool { lock.withLock { _fired } }
        func armOnce(_ block: @escaping () -> Void) { lock.withLock { pending = block; _fired = false } }
        func fire() {
            let block: (() -> Void)? = lock.withLock {
                defer { pending = nil }
                if pending != nil { _fired = true }
                return pending
            }
            block?()
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

    var root: URL!
    var settings: LaunchSettings!
    var launches: [TPPBookRegistry] = []
    let clock = PositionTestClock()
    let sequenceHook = SequenceHook()
    let account = "perbook-\(UUID().uuidString)"

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

    var registryDirectory: URL { registryDirectory(of: account) }

    func registryDirectory(of account: String) -> URL {
        root.appendingPathComponent(account).appendingPathComponent("registry")
    }
    var primaryURL: URL { registryDirectory.appendingPathComponent("registry.json") }
    var booksDirectory: URL { registryDirectory.appendingPathComponent("books") }
    var stateURL: URL { registryDirectory.appendingPathComponent("books-state.json") }

    func dependencies(_ log: LaunchLog, loansFeed: (any OPDSFeedFetching)? = nil) -> RegistryExternalDependencies {
        let root = self.root!
        let settings = self.settings!
        let clock = self.clock
        let sequenceHook = self.sequenceHook
        return RegistryExternalDependencies(
            downloadService: { NoContentDownloadService() },
            loansFeedFetcher: { loansFeed ?? UnreachableLoansFeed() },
            sideloadedIdentifiers: { [] },
            registryDirectory: { root.appendingPathComponent($0, isDirectory: true) },
            onAvailabilityChange: { _, _ in },
            beforeRegistryWrite: { try log.beforeWrite($0, $1) },
            positionClock: { clock.now },
            afterSaveSequence: { _ in sequenceHook.fire() },
            perBookStorageEnabled: { settings.flag },
            appVersion: { settings.version },
            backupClock: { clock.now }
        )
    }

    /// A new registry over the same files, loaded: an app launch.
    @discardableResult
    func launch(
        _ log: LaunchLog = LaunchLog(),
        scope: (any AccountScopeProviding)? = nil,
        loansFeed: (any OPDSFeedFetching)? = nil,
        account loadAccount: String? = nil
    ) async -> TPPBookRegistry {
        let registry = TPPBookRegistry(
            accountScope: scope ?? PositionTestAccountScope(account),
            imageLoader: MockImageLoader(),
            dependencies: dependencies(log, loansFeed: loansFeed)
        )
        launches.append(registry)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: loadAccount ?? account) { continuation.resume() }
        }
        await settle(registry)
        return registry
    }

    /// Waits for queued saves, including a fallback save the disk queue hands
    /// back to the main queue.
    func settle(_ registry: TPPBookRegistry) async {
        await registry._awaitPendingPersistenceForTesting()
        await drainMainQueueAsync()
        await registry._awaitPendingPersistenceForTesting()
    }

    func shelf(_ registry: TPPBookRegistry) -> [String: ShelfEntry] {
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

    func writePrimary(_ json: String) throws {
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: primaryURL)
    }

    func book(_ id: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: id, title: "Book \(id)", distributorType: .EpubZip)
    }

    func location(_ value: String) -> TPPBookLocation? {
        TPPBookLocation(locationString: value, renderer: "test-renderer")
    }

    /// Every file under the account's registry folder, by relative path.
    func files() -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: registryDirectory, includingPropertiesForKeys: nil) else { return result }
        let prefix = registryDirectory.resolvingSymlinksInPath().path + "/"
        for case let url as URL in enumerator {
            guard let data = try? Data(contentsOf: url) else { continue }
            result[url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")] = data
        }
        return result
    }

    func perBookState(of account: String? = nil) -> [String: Any]? {
        let url = registryDirectory(of: account ?? self.account).appendingPathComponent("books-state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The per-book files merged back into whole records, by identifier: each
    /// record file, with its position file's location when that is newer.
    func perBookRecords(of account: String? = nil) -> [String: NSDictionary] {
        let books = registryDirectory(of: account ?? self.account).appendingPathComponent("books")
        var records: [String: (record: [String: Any], sequence: Int)] = [:]
        var positions: [String: (location: Any?, sequence: Int)] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: books.path)) ?? []
        for name in names {
            guard let data = try? Data(contentsOf: books.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["identifier"] as? String else { continue }
            let sequence = object["sequence"] as? Int ?? 0
            if name.hasSuffix(".record.json"), let record = object["record"] as? [String: Any] {
                records[id] = (record, sequence)
            }
            if name.hasSuffix(".position.json") { positions[id] = (object["location"], sequence) }
        }
        var merged: [String: NSDictionary] = [:]
        for (id, entry) in records {
            var record = entry.record
            if let position = positions[id], position.sequence > entry.sequence { record["location"] = position.location }
            merged[id] = record as NSDictionary
        }
        return merged
    }

    /// The records of a registry file by identifier, last one winning, as load reads them.
    func primaryRecords(_ json: String) -> [String: NSDictionary] {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var result: [String: NSDictionary] = [:]
        for record in object["records"] as! [[String: Any]] {
            guard let id = (record["metadata"] as? [String: Any])?["id"] as? String else { continue }
            result[id] = record as NSDictionary
        }
        return result
    }

    /// The location string `registry.json` holds for a book.
    func singleFileLocation(of identifier: String, account: String? = nil) throws -> String? {
        let url = registryDirectory(of: account ?? self.account).appendingPathComponent("registry.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let records = object?["records"] as? [[String: Any]] ?? []
        return records.first { ($0["metadata"] as? [String: Any])?["id"] as? String == identifier }
            .flatMap { ($0["location"] as? [String: Any])?["locationString"] as? String }
    }

    func schemaVersion(_ json: String) -> Int? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["schemaVersion"] as? Int
    }

    /// Each book's entry equals its entry before or after an interrupted save.
    func assertEachBook(_ reloaded: [String: ShelfEntry], before: [String: ShelfEntry], after: [String: ShelfEntry],
                        _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for id in Set(before.keys).union(after.keys).union(reloaded.keys).sorted() {
            XCTAssertTrue(reloaded[id] == before[id] || reloaded[id] == after[id],
                          "\(context): \(id) is \(reloaded[id].map { "\($0)" } ?? "absent"); before \(before[id].map { "\($0)" } ?? "absent"), after \(after[id].map { "\($0)" } ?? "absent")",
                          file: file, line: line)
        }
    }

    /// A migrated three-book shelf with positions, written by an earlier launch.
    func seedMigratedShelf(account seedAccount: String? = nil) async throws {
        let seedAccount = seedAccount ?? account
        settings.flag = false
        let first = await launch(scope: PositionTestAccountScope(seedAccount), account: seedAccount)
        for id in ["a", "b", "c"] { first.addBook(book(seedAccount == account ? id : "\(seedAccount)-\(id)"), state: .holding) }
        await settle(first)
        let prefix = seedAccount == account ? "" : "\(seedAccount)-"
        first.setLocation(location("a-1"), forIdentifier: prefix + "a")
        first.setLocation(location("b-1"), forIdentifier: prefix + "b")
        await settle(first)
        settings.flag = true
        await launch(scope: PositionTestAccountScope(seedAccount), account: seedAccount)
        XCTAssertEqual(perBookState(of: seedAccount)?["verified"] as? Bool, true, "premise: the seeded shelf moved to the per-book layout")
    }
}
