//
//  ColdStartResumeIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for cold-start state reconciliation.
//
//  Pins the production contract from
//  Palace/Book/Models/BookRegistrySync.swift (load(account:setState:completion:)):
//
//    * .downloading records whose content file is missing must be healed
//      to .downloadFailed on load — NOT silently treated as in-flight.
//    * .downloading records whose content file IS present must be promoted
//      to .downloadSuccessful (the download completed before the previous
//      app exit terminated the process).
//    * Corrupted registry JSON must produce an empty in-memory registry —
//      no crash, no partial parse.
//    * Missing registry file must produce an empty registry too.
//    * Proactive token refresh fires when authTokenNearExpiry returns true —
//      see TPPNetworkExecutor.executeRequest:executeRequest enableTokenRefresh
//      branch.
//
//  These tests exercise the real BookRegistrySync.load() pipeline against
//  on-disk fixtures and assert the post-load registry contents.
//
//  House rules: hermetic (HTTPStubURLProtocol-only when networking),
//  temp-dir-scoped account UUIDs, real types, no production code changes.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ColdStartResumeIntegrationTests: XCTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
        account = "test-coldstart-\(UUID().uuidString)"
        accountsManager = AccountsManager()
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        if let regUrl = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: regUrl)
        }
        // Remove the per-account application-support directory entirely.
        if let dir = TPPBookContentMetadataFilesHelper.directory(for: account) {
            try? FileManager.default.removeItem(at: dir)
        }
        accountsManager?.userAccount(for: account).removeAll()
        sync = nil
        store = nil
        accountsManager = nil
        account = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Loads the registry from disk and waits for the `.loaded` state callback.
    private func loadAndWait(account: String) {
        let exp = expectation(description: "load(\(account)) completes")
        sync.load(account: account, setState: { state in
            if state == .loaded { exp.fulfill() }
        }, completion: nil)
        // 120s budget — the prior 30s bump (from 5s) wasn't enough under
        // heavy CI-runner contention. Local runs resolve in <0.5s. Same
        // family as TokenRefreshAndRetryQueue, BookRegistryMigration, and
        // AppContainerImageLoaderInjection timeout bumps.
        wait(for: [exp], timeout: 120.0) // FLAKE-003-OK: cold-start integration test — exercises real BookRegistrySync.load() pipeline through disk I/O, JSON deserialization, per-record state-machine reconciliation, and main-queue publisher hops; 120s budget covers CI runners under memory pressure (AccountsManager preload alone has been seen >5s).
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    /// Writes a raw JSON blob to the registry file path for `account`,
    /// creating intermediate directories.
    private func writeRaw(_ data: Data, to account: String) {
        guard let url = sync.registryUrl(for: account) else {
            XCTFail("registryUrl(for:) returned nil for \(account)")
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Builds a registry JSON dictionary representation that
    /// BookRegistrySync.load can deserialize back into a TPPBookRegistryRecord.
    private func recordJSON(identifier: String,
                            title: String = "Cold Start Book",
                            state: TPPBookState) -> [String: Any] {
        let book = TPPBookMocker.mockBook(
            identifier: identifier,
            title: title,
            distributorType: .EpubZip
        )
        let record = TPPBookRegistryRecord(book: book, state: state)
        return record.dictionaryRepresentation
    }

    /// Wraps an array of record dicts in the registry file's outer shape.
    private func registryFileJSON(records: [[String: Any]]) -> Data {
        let payload: [String: Any] = ["records": records]
        return try! JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - In-flight downloads on cold start

    /// `.downloading` with NO file on disk must heal to `.downloadFailed`.
    /// Pins the explicit branch in BookRegistrySync.load (lines 111-118).
    /// Kills mutant: changing `.downloadFailed` → `.downloading` (i.e., silently
    /// resuming) when the file is missing.
    func testColdStart_InflightDownloadWithMissingFile_MarkedFailed() {
        let bookId = "inflight-missing-\(UUID().uuidString)"
        let payload = registryFileJSON(records: [
            recordJSON(identifier: bookId, state: .downloading)
        ])
        writeRaw(payload, to: account)

        loadAndWait(account: account)

        let state = store.state(for: bookId)
        XCTAssertEqual(state, .downloadFailed,
                       "Cold-start: in-flight download with missing file must be marked .downloadFailed, got \(state)")
        XCTAssertNotNil(store.book(forIdentifier: bookId),
                        "The record must remain in the registry — only its state changes")
    }

    /// `.downloading` WITH a file already on disk must be promoted to
    /// `.downloadSuccessful` on load. The previous app exit terminated mid-write
    /// after the file was already complete.
    /// Pins BookRegistrySync.load lines 111-115.
    ///
    /// Uses the `directoryProvider` test seam on `MyBooksDownloadCenter` /
    /// `BookFileManager` so the synthetic test account resolves to a temp
    /// directory we control. Both the file we stage on disk AND the sync's
    /// reconciliation pass go through the same `MyBooksDownloadCenter`
    /// instance — so the path the sync probes is exactly the path we wrote.
    func testColdStart_InflightDownloadWithExistingFile_PromotedToSuccessful() throws {
        let bookId = "inflight-present-\(UUID().uuidString)"
        let payload = registryFileJSON(records: [
            recordJSON(identifier: bookId, state: .downloading)
        ])
        writeRaw(payload, to: account)

        // Stand up an isolated temp directory + a MyBooksDownloadCenter
        // wired to it via the new `directoryProvider` seam. Production code
        // path (when `directoryProvider` is nil) is unchanged.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MBDC-coldstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let testDownloadCenter = MyBooksDownloadCenter(
            accountsManager: accountsManager,
            directoryProvider: { _ in tempRoot }
        )
        // Rebuild sync so it routes through our test download center for
        // both the on-disk URL lookup AND the reconcile-on-load probe.
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { testDownloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )

        // Drop a sentinel file on disk where the download center would expect it.
        // Production checks `MyBooksDownloadCenter.fileUrl(for:account:)`.
        let placeholderBook = TPPBookMocker.mockBook(
            identifier: bookId, title: "Inflight Present", distributorType: .EpubZip
        )
        guard let fileURL = testDownloadCenter.fileUrl(
            for: placeholderBook, account: account
        ) else {
            XCTFail("directoryProvider seam returned nil — the test seam is broken")
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("present".utf8).write(to: fileURL)

        loadAndWait(account: account)

        let state = store.state(for: bookId)
        // Production heals .downloading→.downloadSuccessful when file is present.
        XCTAssertEqual(state, .downloadSuccessful,
                       "Cold-start with file present: .downloading must be promoted to .downloadSuccessful, got \(state)")
    }

    // MARK: - Corrupted / missing registry on cold start

    /// Cold-start with a corrupted registry file must produce an EMPTY
    /// in-memory registry — and not crash. Pins BookRegistrySync.load's
    /// `try? JSONSerialization.jsonObject(...)` defensive parse.
    /// Kills mutant: replacing `try?` with `try!` (would crash).
    func testColdStart_CorruptedRegistryFile_BootsToEmptyState() {
        let garbage = Data("not-valid-json-{[]}".utf8)
        writeRaw(garbage, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Cold-start with corrupted registry must yield an empty registry — no partial parse, no crash")
    }

    /// Cold-start with NO registry file (fresh install / cleared data)
    /// must produce an empty registry without error. This is the no-op
    /// branch on `FileManager.default.fileExists(atPath: url.path) == false`.
    func testColdStart_NoRegistryFile_BootsToEmptyState() {
        // Do NOT write anything — the registry directory may not even exist.
        // This is the fresh-install path.
        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Cold-start with no registry file must yield an empty in-memory registry")
    }

    /// Cold-start with a structurally-valid file but missing the `records`
    /// key must boot empty (production code guards on `json.array(for: .records)`).
    func testColdStart_RegistryFileMissingRecordsKey_BootsToEmptyState() {
        let unrelated = Data("{\"version\":42,\"other\":\"stuff\"}".utf8)
        writeRaw(unrelated, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Cold-start with structurally-valid JSON but no records array must yield an empty registry")
    }

    /// Cold-start with an empty records array must yield an empty registry
    /// — and the My Books surface must render empty. Pins the trivial
    /// "freshly-signed-in but no loans yet" path.
    func testColdStart_EmptyRecordsArray_RendersEmptyMyBooks() {
        let payload = registryFileJSON(records: [])
        writeRaw(payload, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Cold-start with empty records array must yield an empty registry")
        XCTAssertTrue(store.myBooks.isEmpty,
                      "My Books must be empty when the registry has no records")
    }

    // MARK: - Half-borrowed book reconciliation

    /// Cold-start with a .downloadNeeded record (borrow succeeded but download
    /// never started) MUST keep the record present so the sync against the
    /// loans feed can reconcile it. We assert the record is preserved through
    /// the load — sync's server reconciliation pass is the next step in the
    /// app lifecycle and is exercised in BookRegistrySync sync tests.
    /// Pins the "carry .downloadNeeded through load" path.
    func testColdStart_HalfBorrowedBook_RecordPreservedForServerReconciliation() {
        let bookId = "half-borrow-\(UUID().uuidString)"
        let payload = registryFileJSON(records: [
            recordJSON(identifier: bookId, state: .downloadNeeded)
        ])
        writeRaw(payload, to: account)

        loadAndWait(account: account)

        XCTAssertNotNil(store.book(forIdentifier: bookId),
                        "Half-borrowed (.downloadNeeded) book must survive cold-start so sync can reconcile it")
        // The state is either .downloadNeeded (no file) or .downloadSuccessful (heal-on-file-present).
        let state = store.state(for: bookId)
        XCTAssertTrue(state == .downloadNeeded || state == .downloadSuccessful,
                      "Loaded state for a half-borrowed book must be .downloadNeeded (file missing) or .downloadSuccessful (heal); got \(state)")
    }

    // MARK: - Stale-token proactive refresh

    /// Pins TPPUserAccount.authTokenNearExpiry contract:
    /// a token within the refresh-threshold window must report true. The
    /// TPPNetworkExecutor branch on this property is what fires proactive
    /// refresh BEFORE the first user-driven request.
    /// Kills mutant: flipping the `<=` to `>=` in isTokenNearExpiry.
    func testColdStart_StaleTokenDetectedAsNearExpiry() {
        // Token expiring in 30 seconds — well within the production refresh
        // threshold of 5 minutes.
        let staleExpiry = Date().addingTimeInterval(30)
        let userAccount = accountsManager.userAccount(for: account)
        userAccount.setAuthToken("stale-token", barcode: "b", pin: "p", expirationDate: staleExpiry)

        XCTAssertTrue(userAccount.authTokenNearExpiry,
                      "Token with expiry within refresh window must report authTokenNearExpiry = true")
        XCTAssertFalse(userAccount.authTokenHasExpired,
                       "Token expiring in 30s is near-expiry but NOT yet expired")
    }

    /// Pins the post-TTL classification: a token whose expiry has already
    /// passed must report `authTokenHasExpired = true`. This is the trigger
    /// for forcing re-auth on cold-start.
    func testColdStart_TokenPastExpiry_ReportsExpired() {
        let pastExpiry = Date().addingTimeInterval(-3600) // expired 1h ago
        let userAccount = accountsManager.userAccount(for: account)
        userAccount.setAuthToken("expired-token", barcode: "b", pin: "p", expirationDate: pastExpiry)

        XCTAssertTrue(userAccount.authTokenHasExpired,
                      "Token whose expiry has passed must report authTokenHasExpired = true")
    }

    /// A fresh token (well outside the refresh window) must NOT trigger
    /// proactive refresh. Pins the negative branch of authTokenNearExpiry.
    /// Kills the mutant that always returns true.
    func testColdStart_FreshTokenNotMarkedNearExpiry() {
        let freshExpiry = Date().addingTimeInterval(3600) // 1h from now
        let userAccount = accountsManager.userAccount(for: account)
        userAccount.setAuthToken("fresh-token", barcode: "b", pin: "p", expirationDate: freshExpiry)

        XCTAssertFalse(userAccount.authTokenNearExpiry,
                       "Token with 1h until expiry must NOT report near-expiry")
        XCTAssertFalse(userAccount.authTokenHasExpired,
                       "Token with 1h until expiry must NOT report expired")
    }
}
