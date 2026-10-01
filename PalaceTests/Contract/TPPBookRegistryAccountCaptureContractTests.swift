//
//  TPPBookRegistryAccountCaptureContractTests.swift
//  PalaceTests
//
//  Pins PP-4129: every `TPPBookRegistry` mutation captures the current account uuid
//  at dispatch time, so a save that commits after a switch to account B still lands
//  in A's registry file. Without it, a mid-flight library switch retargets the save
//  ("books downloaded, but open to a 401 re-auth loop").
//  Drives a mutation on A, flips `currentAccount` to B before the save barrier
//  joins, and asserts A's file. `saveSync()` persists synchronously, so its case
//  pins the synchronously-current account instead.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class TPPBookRegistryAccountCaptureContractTests: PalaceWiringTestCase {

    // Fresh, non-default UUIDs so each account maps to its OWN registry directory
    // (TPPBookContentMetadataFilesHelper.directory only omits the account subdir
    // for TPPAccountUUIDs[0]).
    private let accountAUUID = "acct-capture-A-\(UUID().uuidString)"
    private let accountBUUID = "acct-capture-B-\(UUID().uuidString)"

    // Single-threaded serial test lifecycle (test body + nonisolated
    // tearDownWithError run serially on one instance), so the unsafe opt-out is
    // race-free — mirrors PalaceWiringTestCase.cancellables.
    nonisolated(unsafe) private var seededRegistryDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in seededRegistryDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        seededRegistryDirs.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func makeAccount(uuid: String) -> Account {
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog",
                              rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: uuid, title: "Fixture \(uuid)"),
            images: nil
        )
        return Account(publication: pub, imageCache: MockImageCache())
    }

    /// Builds a facade whose currentAccount starts as A, and tracks both
    /// accounts' registry directories for cleanup.
    private func makeHarness() -> (registry: TPPBookRegistry, manager: AccountsManager) {
        let manager = makeFreshAccountsManager()
        let registry = TPPBookRegistry(accountsManager: manager, imageLoader: MockImageLoader())
        if let a = registry.registryUrl(for: accountAUUID)?.deletingLastPathComponent() {
            seededRegistryDirs.append(a)
        }
        if let b = registry.registryUrl(for: accountBUUID)?.deletingLastPathComponent() {
            seededRegistryDirs.append(b)
        }
        return (registry, manager)
    }

    /// Seed A as current. (Cleanup handled by PalaceWiringTestCase reset +
    /// per-dir removal in tearDown.)
    private func seedCurrentA(_ manager: AccountsManager) {
        _ = manager._seedAccountForTesting(makeAccount(uuid: accountAUUID))
    }

    /// Flip currentAccount to B (keeps A in the account set).
    private func flipCurrentToB(_ manager: AccountsManager) {
        _ = manager._seedAccountForTesting(makeAccount(uuid: accountBUUID))
    }

    private func fileExists(forAccount uuid: String, registry: TPPBookRegistry) -> Bool {
        guard let url = registry.registryUrl(for: uuid) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Parse a persisted registry record for `id` from `account`'s on-disk file.
    private func onDiskRecord(forAccount uuid: String, id: String, registry: TPPBookRegistry) -> TPPBookRegistryRecord? {
        guard let url = registry.registryUrl(for: uuid),
              let data = try? Data(contentsOf: url),
              case .valid(let records) = RegistryFileRecovery.classify(data: data)
        else { return nil }
        for obj in records {
            if let rec = TPPBookRegistryRecord(record: obj), rec.book.identifier == id { return rec }
        }
        return nil
    }

    private func makeBook(id: String) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: id,
            imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
            subtitle: nil, summary: nil, title: "Book \(id)", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    /// Deterministic join on the async save: drain the registry's store-write
    /// barrier (so each mutation's `onComplete` has enqueued its `save(...)`) and
    /// then the sync engine's disk-write queue (so the bytes have flushed), so a
    /// subsequent on-disk assertion is race-free. Replaces a
    /// `.TPPBookRegistryDidChange` deadline wait — no wall-clock timeout to starve
    /// under parallel sim clones (STARVE-001).
    private func awaitPersisted(_ registry: TPPBookRegistry) async {
        await registry._awaitPendingPersistenceForTesting()
    }

    // MARK: - addBook

    /// addBook captures A at dispatch; a flip to B before the barrier's save runs
    /// must NOT retarget the write. The book must land in A's registry, and B's
    /// registry file must never be created.
    func testAddBook_capturesAccountAtDispatch_persistsToOriginalAccount() async {
        let (registry, manager) = makeHarness()
        seedCurrentA(manager)

        let id = "cap-add-\(UUID().uuidString)"
        registry.addBook(makeBook(id: id), state: .downloadNeeded)   // captures A
        flipCurrentToB(manager)                                       // user switches libraries

        await awaitPersisted(registry)

        XCTAssertNotNil(onDiskRecord(forAccount: accountAUUID, id: id, registry: registry),
                        "addBook must persist to the ORIGINALLY-captured account A")
        XCTAssertFalse(fileExists(forAccount: accountBUUID, registry: registry),
                       "the mid-flight switch to B must NOT retarget the save — B's registry must never be written")
    }

    // MARK: - setState

    /// setState captures A at dispatch; a flip to B before its save barrier runs
    /// must persist the new state to A, not B.
    func testSetState_capturesAccountAtDispatch_persistsToOriginalAccount() async {
        let (registry, manager) = makeHarness()
        seedCurrentA(manager)

        let id = "cap-setstate-\(UUID().uuidString)"
        registry.addBook(makeBook(id: id), state: .downloadNeeded)   // captures A
        await awaitPersisted(registry)

        registry.setState(.downloading, for: id)                     // captures A (legal transition)
        flipCurrentToB(manager)                                      // user switches libraries

        await awaitPersisted(registry)

        XCTAssertEqual(onDiskRecord(forAccount: accountAUUID, id: id, registry: registry)?.state, .downloading,
                       "setState must persist the new state to the ORIGINALLY-captured account A")
        XCTAssertFalse(fileExists(forAccount: accountBUUID, registry: registry),
                       "the mid-flight switch to B must NOT retarget the setState save")
    }

    // MARK: - bookmark wrapper (readium)

    /// The readium-bookmark add wrapper captures A at dispatch and routes the save
    /// through a store barrier `onComplete`; a flip to B must persist the bookmark
    /// to A, not B.
    func testAddReadiumBookmark_capturesAccountAtDispatch_persistsToOriginalAccount() async {
        let (registry, manager) = makeHarness()
        seedCurrentA(manager)

        let id = "cap-bookmark-\(UUID().uuidString)"
        registry.addBook(makeBook(id: id), state: .downloadSuccessful) // captures A
        await awaitPersisted(registry)

        let bookmark = TPPReadiumBookmark(
            annotationId: "anno-\(UUID().uuidString)",
            href: "chapter1.xhtml",
            chapter: "Ch 1",
            page: nil,
            location: nil,
            progressWithinChapter: 0.25,
            progressWithinBook: 0.1,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: nil,
            device: "test"
        )!
        registry.add(bookmark, forIdentifier: id)                     // captures A
        flipCurrentToB(manager)                                       // user switches libraries

        await awaitPersisted(registry)

        XCTAssertEqual(onDiskRecord(forAccount: accountAUUID, id: id, registry: registry)?.readiumBookmarks?.count, 1,
                       "the bookmark must persist to the ORIGINALLY-captured account A")
        XCTAssertFalse(fileExists(forAccount: accountBUUID, registry: registry),
                       "the mid-flight switch to B must NOT retarget the bookmark save")
    }

    // MARK: - saveSync (synchronous capture)

    /// `saveSync()` reads currentAccount and persists SYNCHRONOUSLY (a blocking
    /// `diskWriteQueue.sync`), so there is no async window to interleave a flip.
    /// This pins that it targets the synchronously-current account: we delete A's
    /// file, call saveSync while A is current, and assert A is recreated while B
    /// is never written.
    func testSaveSync_persistsToCurrentAccount_synchronously() async {
        let (registry, manager) = makeHarness()
        seedCurrentA(manager)

        let id = "cap-savesync-\(UUID().uuidString)"
        registry.addBook(makeBook(id: id), state: .downloadNeeded)
        await awaitPersisted(registry)

        // Delete A's file so a successful saveSync must recreate it.
        if let url = registry.registryUrl(for: accountAUUID) {
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertFalse(fileExists(forAccount: accountAUUID, registry: registry),
                       "precondition: A's registry file removed")

        registry.saveSync()   // synchronous capture (A) + synchronous write

        XCTAssertNotNil(onDiskRecord(forAccount: accountAUUID, id: id, registry: registry),
                        "saveSync must persist synchronously to the current account A")
        XCTAssertFalse(fileExists(forAccount: accountBUUID, registry: registry),
                       "saveSync must not write any other account's registry")
    }
}
