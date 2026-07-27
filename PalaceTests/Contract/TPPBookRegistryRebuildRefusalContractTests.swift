//
//  TPPBookRegistryRebuildRefusalContractTests.swift
//  PalaceTests
//
//  God-class decomposition Wave 2b — the INV-1 rebuild-window save-refusal
//  contract for `BookRegistrySync.save(for:serverAuthoritative:)`.
//
//  INV-1 (Reliability WS-B): after a corrupt load leaves the in-memory shelf
//  empty (quarantining the corrupt primary, `needsRebuildFromServer == true`), a
//  NON-authoritative empty save MUST be REFUSED so it cannot overwrite the
//  last-good `.bak` (and never materializes a valid-empty primary that erases the
//  patron's shelf) before an authoritative server sync repopulates it. An
//  AUTHORITATIVE empty save (the loans-feed reconciliation result) is ALLOWED and
//  CLEARS the rebuild flag.
//
//  This pins the ordered DECISION sequence — refuse-then-allow — not just a single
//  terminal outcome. The two decisions are recorded into a `CallLog` and snapshot;
//  a mutant that inverts the guard (persists the non-authoritative empty, or
//  refuses the authoritative one, or fails to clear/keep the flag) drifts the
//  snapshot. Explicit disk/flag assertions back the snapshot up.
//
//  Distinct from the OUTCOME-level INV-1 tests already in BookRegistrySyncTests
//  (which assert each half in isolation): this locks the SEQUENCE across a single
//  rebuild window so a reorder or an early flag-clear is caught.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TPPBookRegistryRebuildRefusalContractTests: XCTestCase {

    private var store: BookRegistryStore!
    private var syncManager: BookRegistrySync!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = BookRegistryStore()
        let appContainer = makeTestAppContainer()
        syncManager = BookRegistrySync(
            store: store,
            accountsManager: appContainer.accountsManager,
            downloadCenterProvider: { appContainer.downloadCenter },
            opdsFeedServiceProvider: { appContainer.opdsFeedService }
        )
    }

    override func tearDownWithError() throws {
        syncManager = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers (mirror the isolated-account disk pattern)

    private func makeIsolatedAccount() -> (String, URL) {
        let account = "rebuild-contract-\(UUID().uuidString)"
        let url = syncManager.registryUrl(for: account)!
        return (account, url)
    }

    private func cleanupAccount(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
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

    /// One-book snapshot in the exact persisted dictionary shape, then clears the
    /// store — used to seed a non-empty last-good `.bak`. Synchronous: the test
    /// method must NOT be async, else the `wait(for:)` joins below would block the
    /// main actor and starve the save's main-queue notification post.
    private func snapshotWithOneBook(id: String) -> [[String: Any]] {
        let added = expectation(description: "added")
        store.addBook(makeBook(id: id), state: .downloadNeeded) { _ in added.fulfill() }
        wait(for: [added], timeout: 2.0)
        drainMainQueue()
        let snapshot = store.registrySnapshot()
        store.removeAll()
        drainMainQueue()
        return snapshot
    }

    private func writeRegistryPayload(records: [[String: Any]], schemaVersion: Int?, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var json: [String: Any] = [TPPBookRegistryKey.records.rawValue: records]
        if let schemaVersion { json[RegistryFileRecovery.schemaVersionKey] = schemaVersion }
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: url)
    }

    /// Join a SUCCESSFUL disk write via the `.TPPBookRegistryDidChange` the save
    /// posts after `write(to:)` lands.
    private func awaitRegistrySaved(timeout: TimeInterval = 5.0, _ action: () -> Void) {
        let saved = expectation(description: "registry disk write posted TPPBookRegistryDidChange")
        saved.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange, object: nil, queue: .main
        ) { _ in saved.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        action()
        wait(for: [saved], timeout: timeout)
    }

    /// Fixed run-loop settle for asserting the ABSENCE of an effect (a refused
    /// save posts no notification — there is no positive edge to await).
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func primaryIsValidRegistry(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if case .valid = RegistryFileRecovery.classify(data: data) { return true }
        return false
    }

    // MARK: - Contract

    /// The refuse-then-allow decision sequence across one rebuild window.
    func testRebuildWindow_refusesNonAuthoritativeEmpty_thenAllowsAuthoritativeEmpty() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        // Arrange the post-corrupt rebuild window: a non-empty last-good backup on
        // disk, the SUT flagged for rebuild, and an empty in-memory shelf.
        let goodRecords = snapshotWithOneBook(id: "kept-book")
        XCTAssertEqual(goodRecords.count, 1, "precondition: backup fixture has one record")
        writeRegistryPayload(records: goodRecords, schemaVersion: 1,
                             to: RegistryFileRecovery.backupURL(for: url))
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "precondition: a non-empty .bak exists")
        syncManager.needsRebuildFromServer = true
        XCTAssertTrue(store.allBooks.isEmpty, "precondition: empty in-memory shelf")

        let log = CallLog()

        // --- Decision 1: NON-authoritative empty save → REFUSED ---
        // Refused saves post no notification; settle then observe the disk/flag.
        syncManager.save(for: account) // serverAuthoritative: false
        settle()
        log.record("emptySave", args: [
            "authoritative": false,
            "primaryPersisted": primaryIsValidRegistry(at: url),
            "backupIntact": RegistryFileRecovery.backupHasRecords(for: url),
            "rebuildFlagCleared": !syncManager.needsRebuildFromServer
        ])

        XCTAssertFalse(primaryIsValidRegistry(at: url),
                       "INV-1: a non-authoritative empty save must NOT write a valid-empty primary")
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "INV-1: the non-empty last-good backup must survive a refused empty save")
        XCTAssertTrue(syncManager.needsRebuildFromServer,
                      "INV-1: a refused save must leave the rebuild flag set")

        // --- Decision 2: AUTHORITATIVE empty save → ALLOWED + clears flag ---
        awaitRegistrySaved { syncManager.save(for: account, serverAuthoritative: true) }
        log.record("emptySave", args: [
            "authoritative": true,
            "primaryPersisted": primaryIsValidRegistry(at: url),
            "backupIntact": RegistryFileRecovery.backupHasRecords(for: url),
            "rebuildFlagCleared": !syncManager.needsRebuildFromServer
        ])

        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("an authoritative empty save must persist a valid (empty) registry.json")
        }
        XCTAssertTrue(recs.isEmpty, "the authoritative save persisted the empty shelf")
        XCTAssertFalse(syncManager.needsRebuildFromServer,
                       "an authoritative save must clear the rebuild flag")

        // The ordered refuse → allow decision sequence is the contract.
        ContractSnapshot.assert(log, named: "rebuildWindowRefuseThenAllow")
    }
}
