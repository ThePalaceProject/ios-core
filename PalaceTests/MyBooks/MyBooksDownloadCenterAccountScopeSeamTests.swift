//
//  MyBooksDownloadCenterAccountScopeSeamTests.swift
//  PalaceTests
//
//  Wave 3 S2b — proves `MyBooksDownloadCenter` resolves account SCOPE through
//  the injected `DownloadAccountScopeProviding` seam, NOT a hardcoded
//  `AccountsManager` / `AppContainer.production()` reach.
//
//  Two behavioral pins, both driven by a spy scope so the account-SCOPE reads
//  under test resolve through the spy — no real AccountsManager, keychain, or
//  UserDefaults backs the scope path. (MBDC's OTHER init defaults still resolve
//  `AppContainer.production()` for the credential / networkExecutor / disk-budget
//  deps, which these tests do not exercise; the shared production graph is not a
//  freshly-constructed AccountsManager, so there is no isolation-lint concern.)
//
//    1. `fileUrl(for:)` value-flow — MBDC's default `BookFileManager` resolves
//       the on-disk path under the account the injected seam reports. The spy
//       returns a distinctive id; the account that reaches the file-path
//       `directoryProvider` MUST be exactly that id. A mutant that reverted the
//       retype (BookFileManager reading `AppContainer.production()`'s current
//       account) would resolve a different id here → the assertion fails.
//
//    2. `persistStartedTaskRecord` account stamp — the durable started-task
//       record's `account` is read from the injected seam at persist time. Since
//       PP-4978 that stamp is read back on the DOWNLOAD path to decide whose
//       credentials answer a re-issued request's auth challenge, so a wrong stamp
//       authenticates against the wrong library. (Launch reconciliation itself
//       never reads `.account` — it matches by `bookID`/`taskIdentifier`.)
//       Asserted for a single persist, across a mid-session account change
//       (proving a live read per persist, not an init-time capture), and for the
//       no-current-account sentinel.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

/// Spy `DownloadAccountScopeProviding` — returns a controllable account id +
/// auth-surface hosts and records how many times each is read. `@unchecked
/// Sendable` (the protocol is `Sendable`): all mutable state is NSLock-guarded
/// because the production wire-up can capture it into `@Sendable` host-provider
/// closures.
private final class SpyDownloadAccountScope: DownloadAccountScopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _accountID: String?
    private var _hosts: Set<String>
    private var _accountIDReads = 0
    private var _hostsReads = 0

    init(accountID: String?, hosts: Set<String> = []) {
        self._accountID = accountID
        self._hosts = hosts
    }

    var currentAccountID: String? {
        lock.withLock { _accountIDReads += 1; return _accountID }
    }

    var currentAccountAuthSurfaceHosts: Set<String> {
        lock.withLock { _hostsReads += 1; return _hosts }
    }

    var accountIDReadCount: Int { lock.withLock { _accountIDReads } }
    var hostsReadCount: Int { lock.withLock { _hostsReads } }

    func setAccountID(_ id: String?) { lock.withLock { _accountID = id } }
}

@MainActor
final class MyBooksDownloadCenterAccountScopeSeamTests: XCTestCase {

    private var registry: TPPBookRegistryMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
    }

    override func tearDownWithError() throws {
        registry = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. fileUrl value-flow through the injected seam

    /// The injected scope's `currentAccountID` must be the account under which
    /// MBDC's file-path resolution happens. We record the account string that
    /// reaches the `directoryProvider` — the single choke point every
    /// `fileUrl(for:)` overload funnels through — and assert it equals the spy's
    /// id. This proves MBDC's default `BookFileManager` reads the injected seam,
    /// not `AppContainer.production().accountsManager`.
    func testFileUrl_resolvesPathUnderAccountFromInjectedScopeSeam() throws {
        let seamAccountID = "seam-lib-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: seamAccountID)

        let recordedAccount = LockedBox<String?>(nil)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountScopeSeamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: spy,
            directoryProvider: { account in
                recordedAccount.value = account
                return tempDir
            }
        )

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        let url = center.fileUrl(for: book.identifier)

        XCTAssertNotNil(url,
            "fileUrl must resolve a URL when the registry has the book and the directory provider returns a directory")
        XCTAssertEqual(recordedAccount.value, seamAccountID,
            "MBDC must resolve the download-file path under the account the INJECTED scope seam reports — not a hardcoded AccountsManager / AppContainer.production() read")
        XCTAssertGreaterThan(spy.accountIDReadCount, 0,
            "fileUrl(for:) must consult the injected DownloadAccountScopeProviding.currentAccountID")
    }

    /// A second id proves the read is live, not a coincidence: flip the seam and
    /// the resolved account flips with it. Kills a mutant that captured the id
    /// once at init instead of reading the seam per call.
    func testFileUrl_tracksInjectedScopeSeamAcrossAccountChange() throws {
        let firstID = "seam-first-\(UUID().uuidString)"
        let secondID = "seam-second-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: firstID)

        let recordedAccount = LockedBox<String?>(nil)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountScopeSeamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: spy,
            directoryProvider: { account in
                recordedAccount.value = account
                return tempDir
            }
        )

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadNeeded)

        _ = center.fileUrl(for: book.identifier)
        XCTAssertEqual(recordedAccount.value, firstID)

        spy.setAccountID(secondID)
        _ = center.fileUrl(for: book.identifier)
        XCTAssertEqual(recordedAccount.value, secondID,
            "the file-path account must follow the injected seam's current value on each read — proving a live seam read, not an init-time capture")
    }

    // MARK: - 2. persistStartedTaskRecord stamps the account from the injected seam

    /// The durable started-task record survives a mid-download process kill. Its
    /// `account` is not used by launch reconciliation — that matches by `bookID`
    /// and `taskIdentifier` — but since PP-4978 it is read back on the download
    /// path (`BackgroundDownloadHandler.startedForAccount`) to recover which
    /// library a download was started under when re-issuing its request. A wrong
    /// stamp therefore answers an auth challenge with the wrong library's
    /// credentials. That stamp reads the injected scope seam
    /// (`MyBooksDownloadCenter.persistStartedTaskRecord`), so this test asserts
    /// the persisted record carries exactly the id the spy reports.
    ///
    /// A mutant that re-hardcoded the stamp onto a concrete
    /// `AccountsManager.currentAccountId` — or that stamped the empty-string
    /// fallback unconditionally — persists a different account than the spy's →
    /// the assertion fails.
    func testPersistStartedTaskRecord_stampsAccountFromInjectedScopeSeam() throws {
        let accountID = "stamp-lib-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: accountID)
        let (center, stateManager) = try makeCenterWithIsolatedPersistence(scope: spy)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // DISTINCT urls: production prefers the LIVE task's `originalRequest` over
        // the passed request, because a retry re-issues the task against a
        // refreshed (re-signed) url while the caller still holds the original.
        // Same url in both slots would let a swapped precedence pass.
        let taskURL = try XCTUnwrap(URL(string: "https://example.test/live/\(book.identifier)"))
        let staleRequestURL = try XCTUnwrap(URL(string: "https://example.test/stale/\(book.identifier)"))
        let (task, session) = downloadTask(for: taskURL)
        defer { session.invalidateAndCancel() }

        center.persistStartedTaskRecord(task: task, book: book, request: URLRequest(url: staleRequestURL))

        let records = stateManager.persistedRecords()
        XCTAssertEqual(records.count, 1, "a started task must produce exactly one durable record")
        XCTAssertEqual(records.first?.bookID, book.identifier)
        XCTAssertEqual(records.first?.account, accountID,
            "the durable record's account must be the injected seam's current id — it is read back on the download path to pick the credentials that answer a re-issued request's auth challenge, so a wrong stamp authenticates against the wrong library")
        XCTAssertEqual(records.first?.taskIdentifier, task.taskIdentifier,
            "the record must carry the LIVE task's identifier — reconciliation matches a resumed background task by it, so a wrong value orphans the download")
        XCTAssertEqual(records.first?.downloadURL, taskURL,
            "the live task's originalRequest url must win over the passed request's — a retry re-issues against a refreshed url and the record must track it")
    }

    /// The empty-string account is a LOAD-BEARING sentinel, not a defensive
    /// default: `BackgroundDownloadHandler.startedForAccount` and
    /// `MyBooksDownloadCenter+ChallengeAccount` both branch on
    /// `!startedAccountID.isEmpty` to decide whether to answer a download auth
    /// challenge with the CAPTURED account or fall back to the current one. A
    /// non-empty stand-in (`"unknown"`, `"none"`) reads as a real account id and
    /// routes credentials to `userAccount(forCapturedId:)` for a library that
    /// does not exist — a silent download-auth failure. This pins the nil arm of
    /// the coalescing so that sentinel cannot drift.
    func testPersistStartedTaskRecord_withNoCurrentAccount_stampsEmptySentinel() throws {
        let spy = SpyDownloadAccountScope(accountID: nil)
        let (center, stateManager) = try makeCenterWithIsolatedPersistence(scope: spy)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let url = try XCTUnwrap(URL(string: "https://example.test/\(book.identifier)"))
        let (task, session) = downloadTask(for: url)
        defer { session.invalidateAndCancel() }

        center.persistStartedTaskRecord(task: task, book: book, request: URLRequest(url: url))

        XCTAssertEqual(stateManager.persistedRecords().first?.account, "",
            "with no current account the stamp must be exactly the empty string — consumers test `.isEmpty` to fall back to the current user account, so any other stand-in routes download auth to a nonexistent library")
    }

    /// The stamp must be a LIVE seam read at persist time, not an id captured
    /// when MBDC was constructed. A user switching libraries mid-session and
    /// then starting a download must get the NEW library on the record; an
    /// init-time capture would stamp the old one and answer that download's auth
    /// challenge with the previous library's credentials.
    func testPersistStartedTaskRecord_tracksInjectedScopeSeamAcrossAccountChange() throws {
        let firstID = "first-lib-\(UUID().uuidString)"
        let secondID = "second-lib-\(UUID().uuidString)"
        let spy = SpyDownloadAccountScope(accountID: firstID)
        let (center, stateManager) = try makeCenterWithIsolatedPersistence(scope: spy)

        let firstBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let firstURL = try XCTUnwrap(URL(string: "https://example.test/\(firstBook.identifier)"))
        let (firstTask, firstSession) = downloadTask(for: firstURL)
        defer { firstSession.invalidateAndCancel() }
        center.persistStartedTaskRecord(task: firstTask, book: firstBook, request: URLRequest(url: firstURL))

        spy.setAccountID(secondID)

        let secondBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let secondURL = try XCTUnwrap(URL(string: "https://example.test/\(secondBook.identifier)"))
        let (secondTask, secondSession) = downloadTask(for: secondURL)
        defer { secondSession.invalidateAndCancel() }
        center.persistStartedTaskRecord(task: secondTask, book: secondBook, request: URLRequest(url: secondURL))

        let records = stateManager.persistedRecords()
        XCTAssertEqual(
            records.first(where: { $0.bookID == firstBook.identifier })?.account, firstID,
            "the record written BEFORE the account change must keep the account current at ITS persist time")
        XCTAssertEqual(
            records.first(where: { $0.bookID == secondBook.identifier })?.account, secondID,
            "the record written AFTER the account change must carry the NEW id — proving a live seam read per persist, not an init-time capture")
    }

    // MARK: - Helpers

    /// MBDC wired to the given scope seam and to a `DownloadStateManager` whose
    /// durable store is a throwaway file, so the assertions read back only what
    /// this test wrote and nothing touches the shared production store.
    private func makeCenterWithIsolatedPersistence(
        scope: SpyDownloadAccountScope
    ) throws -> (MyBooksDownloadCenter, DownloadStateManager) {
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AccountScopeSeamTests-tasks-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: storeURL) }

        let stateManager = DownloadStateManager(
            taskPersistence: DownloadTaskPersistence(fileURL: storeURL)
        )
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            accountScope: scope,
            stateManager: stateManager
        )
        return (center, stateManager)
    }

    /// A real, never-resumed `URLSessionDownloadTask` — `persistStartedTaskRecord`
    /// reads `task.taskIdentifier` and `task.originalRequest`, both of which are
    /// populated at creation. The session is returned so the caller can invalidate
    /// it rather than leaking it onto `URLSession.shared`.
    private func downloadTask(for url: URL) -> (URLSessionDownloadTask, URLSession) {
        let session = URLSession(configuration: .ephemeral)
        return (session.downloadTask(with: url), session)
    }
}

/// Minimal thread-safe box so the `@escaping` directory-provider closure (which
/// is not `@Sendable` here but is called synchronously on the main actor) can
/// hand a captured value back to the test without a `var` capture warning under
/// Swift 6.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
