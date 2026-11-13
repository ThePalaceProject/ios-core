//
//  RegistryPositionOnlySaveTests.swift
//  PalaceTests
//
//  PP-5268: a reading or listening position is saved every ~15 seconds of
//  playback. A position-only save still persists the registry file, but it does
//  not refresh the last-good backup and does not announce a shelf change, which
//  the shelf, holds, detail and CarPlay screens all react to.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class RegistryPositionOnlySaveTests: PalaceWiringTestCase {

    /// The registry reads the current library from here; a fixed value lets the
    /// facade test save to a known account without selecting a real library.
    private final class FixedAccountScope: AccountScopeProviding, @unchecked Sendable {
        let currentAccountID: String?
        init(_ accountID: String) { currentAccountID = accountID }
        var accountDidChangePublisher: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        func hasCredentials(forAccount accountID: String) -> Bool { false }
        func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? { nil }
    }

    private var account: String!
    private var appContainer: AppContainer!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private let bookID = "position-only-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        account = "test-position-only-\(UUID().uuidString)"
        store = BookRegistryStore()
        appContainer = makeTestAppContainer()
        let container = appContainer!
        sync = BookRegistrySync(
            store: store,
            accountsManager: container.accountsManager,
            downloadCenterProvider: { container.downloadCenter },
            opdsFeedServiceProvider: { container.opdsFeedService }
        )
    }

    override func tearDownWithError() throws {
        if let url = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        store = nil
        sync = nil
        appContainer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeBook() -> TPPBook {
        TPPBookMocker.mockBook(identifier: bookID, title: "Position Only", distributorType: .EpubZip)
    }

    private func makeLocation(_ locationString: String) -> TPPBookLocation? {
        TPPBookLocation(locationString: locationString, renderer: "test-renderer")
    }

    /// A one-book shelf persisted with a full save, so both the primary file and
    /// the last-good backup exist before the save under test.
    private func seedPersistedShelf(location: String?) throws -> (primary: URL, backup: URL) {
        let book = makeBook()
        store.mutateRegistrySync { registry in
            let record = TPPBookRegistryRecord(book: book, state: .downloadSuccessful)
            record.location = location.flatMap { self.makeLocation($0) }
            registry[self.bookID] = record
        }
        sync.saveSync(for: account)
        let primary = try XCTUnwrap(sync.registryUrl(for: account))
        let backup = RegistryFileRecovery.backupURL(for: primary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "premise: a full save writes the backup")
        return (primary, backup)
    }

    private func setLocationInMemory(_ locationString: String) {
        store.mutateRegistrySync { registry in
            registry[self.bookID]?.location = self.makeLocation(locationString)
        }
    }

    private func persistedLocation(in url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let record = records.first { ($0["metadata"] as? [String: Any])?["id"] as? String == bookID }
        let location = record?["location"] as? [String: Any]
        return location?["locationString"] as? String
    }

    /// Lets main-queue blocks already enqueued (the registry's announcements)
    /// run before counting starts or stops.
    private func settleMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Counts `TPPBookRegistryDidChange` posts caused by `work`, which must
    /// return only after its writes are on disk.
    private func registryChangeCount(during work: () async -> Void) async -> Int {
        await settleMainQueue()
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange, object: nil, queue: nil
        ) { _ in count += 1 }
        await work()
        await settleMainQueue()
        NotificationCenter.default.removeObserver(token)
        return count
    }

    // MARK: - Disk

    func test_positionOnlySave_persistsThePosition_withoutRewritingTheBackup() async throws {
        let files = try seedPersistedShelf(location: "before")
        let backupBefore = try Data(contentsOf: files.backup)

        setLocationInMemory("after")
        sync.save(for: account, scope: .positionOnly)
        await sync._awaitPendingDiskWritesForTesting()

        XCTAssertEqual(try persistedLocation(in: files.primary), "after",
                       "a position-only save must still persist the new position — it is what survives a kill")
        XCTAssertEqual(try Data(contentsOf: files.backup), backupBefore,
                       "a position-only save must leave the last-good backup as it was")
    }

    /// Control for the test above: without it, a change that stopped ALL saves
    /// refreshing the backup would pass.
    func test_shelfSave_stillRefreshesTheBackup() async throws {
        let files = try seedPersistedShelf(location: "before")

        setLocationInMemory("after")
        sync.save(for: account, scope: .shelf)
        await sync._awaitPendingDiskWritesForTesting()

        XCTAssertEqual(try persistedLocation(in: files.backup), "after",
                       "a shelf save must refresh the backup to the snapshot it wrote")
    }

    /// INV-1 is scope-independent: an empty in-memory registry must not clobber a
    /// non-empty shelf on disk, whichever kind of save asks.
    func test_positionOnlySave_ofAnEmptyRegistry_doesNotClobberTheShelfOnDisk() async throws {
        let files = try seedPersistedShelf(location: "kept")
        store.mutateRegistrySync { $0.removeAll() }

        sync.save(for: account, scope: .positionOnly)
        await sync._awaitPendingDiskWritesForTesting()

        XCTAssertEqual(try persistedLocation(in: files.primary), "kept",
                       "the empty-shelf refusal must apply to position-only saves too")
    }

    // MARK: - Broadcast

    func test_positionOnlySave_doesNotAnnounceAShelfChange() async throws {
        _ = try seedPersistedShelf(location: "before")
        setLocationInMemory("after")

        let posts = await registryChangeCount {
            sync.save(for: account, scope: .positionOnly)
            await sync._awaitPendingDiskWritesForTesting()
        }

        XCTAssertEqual(posts, 0, "a position-only save must not tell the shelf screens the shelf changed")
    }

    func test_shelfSave_announcesAShelfChange() async throws {
        _ = try seedPersistedShelf(location: "before")

        let posts = await registryChangeCount {
            sync.save(for: account, scope: .shelf)
            await sync._awaitPendingDiskWritesForTesting()
        }

        XCTAssertEqual(posts, 1, "control: a shelf save still announces the change")
    }

    // MARK: - Facade wiring

    /// Drives the production `TPPBookRegistry.setLocation` end to end: the facade
    /// wires `BookmarkManager.savePosition` to the position-only save. Wired to
    /// the shelf save instead, this test sees the backup rewritten and a post.
    func test_registrySetLocation_persists_withoutAnnouncingOrRewritingTheBackup() async throws {
        let container = appContainer!
        let registry = TPPBookRegistry(
            accountScope: FixedAccountScope(account),
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { container.downloadCenter },
                loansFeedFetcher: { container.opdsFeedService },
                sideloadedIdentifiers: { [] },
                registryDirectory: { TPPBookContentMetadataFilesHelper.directory(for: $0) },
                onAvailabilityChange: { _, _ in }
            )
        )
        let primary = try XCTUnwrap(registry.registryUrl(for: account))
        defer { try? FileManager.default.removeItem(at: primary.deletingLastPathComponent()) }

        registry.addBook(makeBook(), location: makeLocation("before"), state: .downloadSuccessful)
        await registry._awaitPendingPersistenceForTesting()
        let backup = RegistryFileRecovery.backupURL(for: primary)
        let backupBefore = try Data(contentsOf: backup)

        let posts = await registryChangeCount {
            registry.setLocation(makeLocation("after"), forIdentifier: bookID)
            await registry._awaitPendingPersistenceForTesting()
        }

        XCTAssertEqual(posts, 0, "setLocation through the registry must not announce a shelf change")
        XCTAssertEqual(try persistedLocation(in: primary), "after", "setLocation through the registry must persist")
        XCTAssertEqual(try Data(contentsOf: backup), backupBefore,
                       "setLocation through the registry must not rewrite the backup")
    }
}
