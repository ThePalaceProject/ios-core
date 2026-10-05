//
//  RegistryWriteFailureTests.swift
//  PalaceTests
//
//  What a fresh reader of `registry.json` finds after a later save fails. The
//  failures are injected through `RegistryExternalDependencies.beforeRegistryWrite`
//  on the registry the app builds (the facade's designated init), so the real
//  save, backup and load code runs. An injected I/O failure is not a process
//  crash or power loss; that durability is not tested here.
//

import XCTest
@testable import Palace
import PalaceBookModel
import PalaceCatalog
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class RegistryWriteFailureTests: XCTestCase {

    // MARK: - Doubles

    /// Fails armed write steps for one account directory and records which
    /// armed steps fired, so a test cannot pass with a fault that never ran.
    private final class WriteFaults: @unchecked Sendable {
        enum Fault {
            /// Throw before the step writes anything.
            case fail
            /// Leave truncated JSON at the step's URL, then throw: the bytes an
            /// interrupted in-place write would leave behind.
            case tearThenFail
        }
        struct InjectedFailure: Error {}

        static let tornBytes = Data(#"{"schemaVersion":1,"records":[{"metadata":{"id":"#.utf8)

        private let lock = NSLock()
        private var armed: [(step: RegistryWriteStep, directory: String, fault: Fault)] = []
        private var firedSteps: [RegistryWriteStep] = []

        func arm(_ step: RegistryWriteStep, under directory: URL, _ fault: Fault = .fail) {
            lock.lock(); defer { lock.unlock() }
            armed.append((step, directory.path + "/", fault))
        }

        func disarmAll() {
            lock.lock(); defer { lock.unlock() }
            armed.removeAll()
        }

        var fired: [RegistryWriteStep] {
            lock.lock(); defer { lock.unlock() }
            return firedSteps
        }

        func beforeWrite(_ step: RegistryWriteStep, _ url: URL) throws {
            lock.lock()
            let match = armed.first { $0.step == step && url.path.hasPrefix($0.directory) }
            if match != nil { firedSteps.append(step) }
            lock.unlock()

            guard let match else { return }
            if match.fault == .tearThenFail {
                try Self.tornBytes.write(to: url)
            }
            throw InjectedFailure()
        }
    }

    /// Nothing on disk and nothing in flight, so `.holding` records load unchanged.
    private final class NothingOnDiskDownloadService: RegistryDownloadServicing, @unchecked Sendable {
        func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
        func startDownload(for book: TPPBook) {}
        func deleteLocalContent(forBook book: TPPBook, account: String?) {}
        func redownloadLCPContentFile(for book: TPPBook) {}
        func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
        func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
        func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence { .absent }
        func isDownloadInFlight(for book: TPPBook) -> Bool { false }
    }

    /// Load and save never fetch the loans feed; a call would mean a sync ran.
    private struct NoLoansFeed: OPDSFeedFetching {
        func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
            throw URLError(.notConnectedToInternet)
        }
    }

    // MARK: - Fixture

    private var root: URL!
    private var faults: WriteFaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistryWriteFailureTests-\(UUID().uuidString)", isDirectory: true)
        faults = WriteFaults()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        faults = nil
        super.tearDown()
    }

    private func makeRegistry(account: String) -> TPPBookRegistry {
        let root = self.root!
        let faults = self.faults!
        return TPPBookRegistry(
            accountScope: FixedAccountScope(accountID: account),
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { NothingOnDiskDownloadService() },
                loansFeedFetcher: { NoLoansFeed() },
                sideloadedIdentifiers: { [] },
                registryDirectory: { root.appendingPathComponent($0, isDirectory: true) },
                onAvailabilityChange: { _, _ in },
                beforeRegistryWrite: { try faults.beforeWrite($0, $1) }
            )
        )
    }

    private func accountDirectory(_ account: String) -> URL {
        root.appendingPathComponent(account, isDirectory: true)
    }

    private func primaryURL(_ registry: TPPBookRegistry, _ account: String) throws -> URL {
        try XCTUnwrap(registry.registryUrl(for: account))
    }

    private func book(_ id: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: id, title: "Book \(id)", distributorType: .EpubZip)
    }

    private func add(_ ids: [String], to registry: TPPBookRegistry) async {
        for id in ids {
            registry.addBook(book(id), state: .holding)
        }
        await registry._awaitPendingPersistenceForTesting()
    }

    /// A new registry instance for `account` that has finished loading from disk.
    private func freshReader(account: String) async -> TPPBookRegistry {
        let reader = makeRegistry(account: account)
        await withCheckedContinuation { continuation in
            reader.load(account: account) { continuation.resume() }
        }
        await reader._awaitPendingWritesForTesting()
        return reader
    }

    private func ids(of registry: TPPBookRegistry) -> Set<String> {
        Set(registry.allBooks.map(\.identifier))
    }

    private func persistedIDs(at url: URL) -> Set<String>? {
        guard case .valid(let records) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return nil
        }
        return Set(records.compactMap { ($0["metadata"] as? [String: Any])?["id"] as? String })
    }

    private func quarantineCopies(besides url: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return entries.filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Primary write failures

    /// A later save whose primary write fails must leave the last committed
    /// primary in place, so the next launch reads the shelf as it was.
    func testLaterSave_InjectedPrimaryWriteFailure_FreshReaderGetsLastCommittedShelf() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        await add(["seed-0", "seed-1"], to: registry)
        let primary = try primaryURL(registry, account)
        let committedBytes = try Data(contentsOf: primary)

        faults.arm(.primary, under: accountDirectory(account))
        await add(["later"], to: registry)

        XCTAssertEqual(faults.fired, [.primary], "premise: the later save reached the primary write and failed there")
        XCTAssertEqual(try Data(contentsOf: primary), committedBytes,
                       "a failed primary write must leave the committed primary byte-for-byte")
        XCTAssertEqual(persistedIDs(at: RegistryFileRecovery.backupURL(for: primary)), ["seed-0", "seed-1", "later"],
                       "the backup is refreshed before the primary write, so it already holds the failed save")
        let reader = await freshReader(account: account)
        XCTAssertEqual(ids(of: reader), ["seed-0", "seed-1"],
                       "a fresh reader must load the last committed shelf, not an empty one")
    }

    /// A primary left torn by a failed save is quarantined on the next load and
    /// the shelf comes back from the backup, which holds that same save.
    func testLaterSave_PrimaryTornByInjectedFault_FreshReaderRecoversThatSaveFromBackup() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        await add(["seed-0", "seed-1"], to: registry)
        let primary = try primaryURL(registry, account)

        faults.arm(.primary, under: accountDirectory(account), .tearThenFail)
        await add(["later"], to: registry)
        XCTAssertEqual(faults.fired, [.primary], "premise: the later save tore the primary")
        XCTAssertNil(persistedIDs(at: primary), "premise: the primary no longer parses")

        let reader = await freshReader(account: account)

        XCTAssertEqual(ids(of: reader), ["seed-0", "seed-1", "later"],
                       "the backup written before the torn primary must restore the whole shelf")
        XCTAssertEqual(quarantineCopies(besides: primary).count, 1,
                       "the torn primary must be copied aside, not discarded")
    }

    /// Same as above through `saveSync`, the teardown path a reading-position
    /// update takes.
    func testSaveSync_PrimaryTornByInjectedFault_FreshReaderRecoversTheNewPosition() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        registry.addBook(book("reading"), location: TPPBookLocation(locationString: "page-1", renderer: "test"), state: .holding)
        await registry._awaitPendingPersistenceForTesting()

        faults.arm(.primary, under: accountDirectory(account), .tearThenFail)
        registry.setLocationSync(TPPBookLocation(locationString: "page-2", renderer: "test"), forIdentifier: "reading")
        await registry._awaitPendingPersistenceForTesting()
        XCTAssertEqual(faults.fired, [.primary], "premise: the saveSync tore the primary")

        let reader = await freshReader(account: account)

        XCTAssertEqual(reader.location(forIdentifier: "reading")?.locationString, "page-2",
                       "saveSync refreshes the backup before the primary, so the new position survives the torn primary")
    }

    // MARK: - Backup write failures

    /// A failed backup write must not stop the primary from committing, and
    /// must leave the previous backup intact.
    func testLaterSave_InjectedBackupStagingFailure_CommitsPrimary_AndKeepsPreviousBackup() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        await add(["seed-0", "seed-1"], to: registry)
        let primary = try primaryURL(registry, account)
        let backup = RegistryFileRecovery.backupURL(for: primary)

        faults.arm(.backupStaging, under: accountDirectory(account))
        await add(["later"], to: registry)
        XCTAssertEqual(faults.fired, [.backupStaging], "premise: the backup write failed")

        XCTAssertEqual(persistedIDs(at: backup), ["seed-0", "seed-1"],
                       "a failed backup write must leave the previous backup readable")
        let reader = await freshReader(account: account)
        XCTAssertEqual(ids(of: reader), ["seed-0", "seed-1", "later"],
                       "the primary must still commit when only the backup write fails")
    }

    /// `writeBackup` removes the old backup before moving the new one in. A
    /// failure in that gap that also stops the primary write leaves no backup,
    /// but the committed primary still loads; the next good save restores the
    /// backup and clears the staged copy.
    func testBackupReplaceGap_FailureThereAndAtPrimary_ShelfSurvives_AndNextSaveRestoresBackup() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        await add(["seed-0", "seed-1"], to: registry)
        let primary = try primaryURL(registry, account)
        let backup = RegistryFileRecovery.backupURL(for: primary)

        faults.arm(.backupReplace, under: accountDirectory(account))
        faults.arm(.primary, under: accountDirectory(account))
        await add(["later"], to: registry)
        XCTAssertEqual(faults.fired, [.backupReplace, .primary], "premise: both steps failed")
        XCTAssertFalse(exists(backup), "the previous backup is already removed when the replace step runs")

        let reader = await freshReader(account: account)
        XCTAssertEqual(ids(of: reader), ["seed-0", "seed-1"],
                       "with no backup, the committed primary must still load the shelf")

        faults.disarmAll()
        registry.saveSync()
        let entries = try FileManager.default.contentsOfDirectory(atPath: primary.deletingLastPathComponent().path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        XCTAssertEqual(entries, ["registry.json", "registry.json.bak"],
                       "the next good save restores the backup and leaves no staged copy")
        XCTAssertEqual(persistedIDs(at: backup), ["seed-0", "seed-1", "later"])
    }

    // MARK: - Both copies invalid

    /// With both the primary and the backup corrupt there is nothing to recover:
    /// the reader starts empty, keeps both files' bytes, and refuses to write an
    /// empty shelf over them until a server sync rebuilds it.
    func testBothCopiesCorrupt_FreshReaderStartsEmpty_KeepsBothFiles_AndRefusesEmptySave() async throws {
        let account = "acct-\(UUID().uuidString)"
        let registry = makeRegistry(account: account)
        await add(["seed-0", "seed-1"], to: registry)
        let primary = try primaryURL(registry, account)
        let backup = RegistryFileRecovery.backupURL(for: primary)
        let corruptPrimary = Data("{ corrupt primary".utf8)
        let corruptBackup = Data("{ corrupt backup".utf8)
        try corruptPrimary.write(to: primary)
        try corruptBackup.write(to: backup)

        let reader = await freshReader(account: account)
        XCTAssertTrue(reader.allBooks.isEmpty, "a corrupt backup must not be offered as a recovery source")
        XCTAssertEqual(quarantineCopies(besides: primary).count, 1, "the corrupt primary must be copied aside")

        reader.saveSync()

        XCTAssertEqual(try Data(contentsOf: primary), corruptPrimary,
                       "an empty, non-authoritative save must not overwrite the corrupt primary while a rebuild is pending")
        XCTAssertEqual(try Data(contentsOf: backup), corruptBackup, "the corrupt backup must be left in place")
    }

    /// A save that fails during the rebuild window must not end the window: a
    /// later empty, non-authoritative save is still refused.
    func testFailedSaveDuringRebuildWindow_KeepsLaterEmptySaveRefused() async throws {
        let account = "acct-\(UUID().uuidString)"
        let primary = accountDirectory(account)
            .appendingPathComponent("registry", isDirectory: true)
            .appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptPrimary = Data("{ corrupt, no backup".utf8)
        try corruptPrimary.write(to: primary)

        let registry = await freshReader(account: account)
        XCTAssertTrue(registry.allBooks.isEmpty, "premise: nothing recoverable, so a rebuild is pending")

        faults.arm(.backupStaging, under: accountDirectory(account))
        faults.arm(.primary, under: accountDirectory(account))
        await add(["borrowed"], to: registry)
        XCTAssertEqual(faults.fired, [.backupStaging, .primary], "premise: the non-empty save wrote nothing")

        faults.disarmAll()
        registry.removeBook(forIdentifier: "borrowed")
        await registry._awaitPendingPersistenceForTesting()

        XCTAssertEqual(try Data(contentsOf: primary), corruptPrimary,
                       "a failed save must not clear the rebuild flag that refuses this empty save")
    }

    // MARK: - Account separation

    /// A torn primary in one library's registry is recovered from that library's
    /// own backup and does not touch another library's files.
    func testTornPrimaryInOneAccount_RecoversFromItsOwnBackup_OtherAccountUnaffected() async throws {
        let accountA = "acct-a-\(UUID().uuidString)"
        let accountB = "acct-b-\(UUID().uuidString)"
        let registryA = makeRegistry(account: accountA)
        let registryB = makeRegistry(account: accountB)
        await add(["a-0"], to: registryA)
        await add(["b-0"], to: registryB)

        // B's failing save runs before A's later save, so a backup shared across
        // accounts would hold A's shelf when B recovers.
        faults.arm(.primary, under: accountDirectory(accountB), .tearThenFail)
        await add(["b-1"], to: registryB)
        await add(["a-1"], to: registryA)
        XCTAssertEqual(faults.fired, [.primary], "premise: only account B's later save tore its primary")

        let readerA = await freshReader(account: accountA)
        let readerB = await freshReader(account: accountB)

        XCTAssertEqual(ids(of: readerA), ["a-0", "a-1"], "account A must load its own committed shelf")
        XCTAssertEqual(ids(of: readerB), ["b-0", "b-1"], "account B must recover from its own backup, with no A books")
        XCTAssertTrue(quarantineCopies(besides: try primaryURL(readerA, accountA)).isEmpty,
                      "account A's registry must not be quarantined")
        XCTAssertEqual(quarantineCopies(besides: try primaryURL(readerB, accountB)).count, 1)
    }
}
