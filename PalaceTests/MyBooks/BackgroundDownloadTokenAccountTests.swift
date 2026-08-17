//
//  BackgroundDownloadTokenAccountTests.swift
//  PalaceTests
//
//  PP-4978. When a download is re-issued mid-flight — the follow-up request the
//  handler builds after an OPDS-entry / rights step — it must carry the
//  credentials of the library the download was STARTED under, not whichever
//  library happens to be selected when the follow-up is built.
//
//  A patron who switches libraries during a download would otherwise have the
//  new library's bearer token sent to the original library's server. Same
//  credential-isolation boundary as the long-standing cross-account leak
//  invariant in `AccountCredentialResolver` (F-034 / PP-4020), and the same
//  boundary PP-4969 closed for the challenge-answering half of this flow.
//
//  The account a download started under is recoverable from its own durable
//  started-task record, which is written at download start and keyed by book id.
//

import XCTest
import PalaceBookModel
@testable import Palace

/// Inert session so a re-issued task created by the handler can never reach the
/// network. Reuses `InertNoOpURLProtocol` from `BackgroundDownloadHandlerTests`;
/// that file's own session constant is fileprivate, hence a second one here.
private let inertTokenTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [InertNoOpURLProtocol.self]
    return URLSession(configuration: config)
}()

// `PalaceWiringTestCase` rather than `XCTestCase`: it is the sanctioned seam for
// minting an `AccountsManager`, and its tearDown calls
// `cancelAndDrainBackgroundWork()` on every manager it minted. A hand-rolled
// `AccountsManager()` pins the same opt-out flag but leaks that cancellation, and
// `AccountsManagerIsolationLintTests` bans it for exactly that reason. The base is
// already `@MainActor`.
final class BackgroundDownloadTokenAccountTests: PalaceWiringTestCase {

    private let startedLibraryID = "test-uuid-started-\(UUID().uuidString)"

    /// Accounts minted for these tests, torn down after each.
    private var mintedAccounts: [TPPUserAccount] = []

    /// One manager shared by the fixture and the code under test, so credentials
    /// never have to round-trip through the keychain — that round-trip works
    /// locally and fails on CI (-34018), which is how PP-4969 lost a cycle.
    private lazy var testAccountsManager: AccountsManager = makeFreshAccountsManager()

    /// Per-test persistence file, removed in tearDown. Without this the suite
    /// writes started-task records into the process-wide default store and never
    /// cleans them up, which would leak fixture records into sibling suites.
    private lazy var persistenceURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp4978-\(UUID().uuidString).json")

    private lazy var isolatedStateManager = DownloadStateManager(
        taskPersistence: DownloadTaskPersistence(fileURL: persistenceURL))

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip the synchronous disk-cache preload — documented as the root of the
        // FLAKE-003 30s CI timeout. Safe here: nothing in this file reads
        // `accountSets` or `account(uuid:)`.
        // (`deferInitialLoadCatalogsForTesting` is the base class's job.)
        AccountsManager.deferDiskCachePreloadForTesting = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: persistenceURL)
        mintedAccounts.forEach { $0.removeAll() }
        mintedAccounts.removeAll()
        AccountsManager.deferDiskCachePreloadForTesting = false
        try await super.tearDown()
    }

    private func makeAccount(id: String, token: String) -> TPPUserAccount {
        let account = testAccountsManager.userAccount(for: id)
        account.setAuthToken(token, barcode: nil, pin: nil, expirationDate: nil)
        mintedAccounts.append(account)
        return account
    }

    /// Reads the Authorization header off the request the handler actually built,
    /// via the task it stored in the state manager. Deliberately the real
    /// artifact rather than a spy hook: the assertion is about what goes on the
    /// wire, so observing the constructed `URLRequest` is the honest observation.
    /// - Parameter storedUnder: the book the handler stores the new download info
    ///   under, which is the UPDATED book — not necessarily the one the record was
    ///   written for. Parameterized because keying this on the original book would
    ///   structurally prevent a test from ever exercising a divergent-identifier
    ///   re-issue, which is exactly the case the production keying decision exists
    ///   for.
    private func followUpAuthorization(
        _ delegate: MockBackgroundDownloadDelegate,
        storedUnder book: TPPBook
    ) async -> String? {
        await delegate.stateManager.bookIdentifierToDownloadInfo
            .get(book.identifier)?
            .downloadTask
            .originalRequest?
            .value(forHTTPHeaderField: "Authorization")
    }

    // MARK: - The re-issued request's Authorization header

    func testReissuedRequest_afterLibrarySwitch_carriesTheStartedForLibrarysToken() async throws {
        // The heart of PP-4978. The download started under library A; the patron
        // has since switched, so the delegate's `userAccount` is library B.
        // The follow-up request must still authenticate as A.
        let startedAccount = makeAccount(id: startedLibraryID, token: "started-library-token")
        let currentAccount = makeAccount(id: "test-uuid-current-\(UUID().uuidString)",
                                         token: "current-library-token")

        let delegate = MockBackgroundDownloadDelegate(userAccount: currentAccount, stateManager: isolatedStateManager)
        delegate.accountsForCapturedId[startedLibraryID] = startedAccount

        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 4_978_001,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        _ = await handler.followAcquisitionLink(
            from: book,
            originalBook: book,
            originalTask: fakeDownloadTask(),
            session: inertTokenTestSession)

        let observed = await followUpAuthorization(delegate, storedUnder: book)
        let header = try XCTUnwrap(
            observed, "the follow-up request must carry an Authorization header")
        XCTAssertEqual(header, "Bearer started-library-token")
        XCTAssertNotEqual(header, "Bearer current-library-token",
                          "the current library's token must never be sent to the started-for library's server")
    }

    func testReissuedRequest_withNoStartedTaskRecord_fallsBackToTodaysBehaviour() async throws {
        // Documented floor: a download this resolver knows nothing about behaves
        // exactly as it does now, so the change can only narrow the defect.
        let currentAccount = makeAccount(id: "test-uuid-current-\(UUID().uuidString)",
                                         token: "current-library-token")

        let delegate = MockBackgroundDownloadDelegate(userAccount: currentAccount, stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // Deliberately no persistStartedTask call.

        _ = await handler.followAcquisitionLink(
            from: book,
            originalBook: book,
            originalTask: fakeDownloadTask(),
            session: inertTokenTestSession)

        let observed = await followUpAuthorization(delegate, storedUnder: book)
        let header = try XCTUnwrap(observed)
        XCTAssertEqual(header, "Bearer current-library-token")
    }

    func testReissuedRequest_whenTheRecordHasNoAccount_fallsBackToTodaysBehaviour() throws {
        // Not hypothetical: the start path writes `account: currentAccountID ?? ""`,
        // so production emits the empty string whenever no account id resolves.
        let currentAccount = makeAccount(id: "test-uuid-current-\(UUID().uuidString)",
                                         token: "current-library-token")

        let delegate = MockBackgroundDownloadDelegate(userAccount: currentAccount, stateManager: isolatedStateManager)
        // Register an account under the EMPTY id. Without this the spy would fall
        // back to `userAccount` for an unknown id, so dropping the emptiness guard
        // would still resolve to `userAccount` and this test would pass for the
        // wrong reason — it did, until a mutation run caught it.
        delegate.accountsForCapturedId[""] = makeAccount(
            id: "test-uuid-empty-\(UUID().uuidString)", token: "empty-id-token")

        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 4_978_002,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: "",
            expectedBytes: nil)

        XCTAssertIdentical(
            handler.startedForAccount(for: book, delegate: delegate), delegate.userAccount,
            "an empty account id must degrade to today's account, not resolve the empty-id account")
    }

    func testReissuedRequest_whenTheUpdatedBookHasADifferentIdentifier_stillUsesTheOriginalBooksAccount() async throws {
        // The keying decision this change documents as load-bearing: the record is
        // written at download start under the ORIGINAL book, while the follow-up
        // carries an UPDATED book parsed from the server's OPDS2 publication, whose
        // identifier is server-supplied and can differ. Every other test here passes
        // the same book as both, so keying on `updatedBook` would pass all of them
        // — review found exactly that mutant surviving.
        let startedAccount = makeAccount(id: startedLibraryID, token: "started-library-token")
        let currentAccount = makeAccount(id: "test-uuid-current-\(UUID().uuidString)",
                                         token: "current-library-token")

        let delegate = MockBackgroundDownloadDelegate(userAccount: currentAccount,
                                                      stateManager: isolatedStateManager)
        delegate.accountsForCapturedId[startedLibraryID] = startedAccount

        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let originalBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let updatedBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        XCTAssertNotEqual(originalBook.identifier, updatedBook.identifier,
                          "fixture precondition: the two books must have different identifiers")

        // Record written under the ORIGINAL book, as the start path does.
        isolatedStateManager.persistStartedTask(
            bookID: originalBook.identifier,
            taskIdentifier: 4_978_020,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        _ = await handler.followAcquisitionLink(
            from: updatedBook,
            originalBook: originalBook,
            originalTask: fakeDownloadTask(),
            session: inertTokenTestSession)

        // The handler stores the new download info under the UPDATED book.
        let observed = await followUpAuthorization(delegate, storedUnder: updatedBook)
        let header = try XCTUnwrap(observed, "the follow-up request must carry an Authorization header")
        XCTAssertEqual(header, "Bearer started-library-token",
                       "keying must follow the ORIGINAL book, which is where the record lives")
    }

    // MARK: - The account the resolver picks

    func testStartedForAccount_picksTheRecordForTheChallengingBook_notTheFirstRecord() throws {
        // Two concurrent downloads from two libraries is the defect scenario. With
        // a single record persisted, a resolver that took the FIRST record would
        // pass every other test here.
        let startedAccount = makeAccount(id: startedLibraryID, token: "started-library-token")
        let otherLibraryID = "test-uuid-other-\(UUID().uuidString)"
        _ = makeAccount(id: otherLibraryID, token: "other-library-token")

        let delegate = MockBackgroundDownloadDelegate(
            userAccount: makeAccount(id: "test-uuid-current-\(UUID().uuidString)",
                                     token: "current-library-token"),
            stateManager: isolatedStateManager)
        delegate.accountsForCapturedId[startedLibraryID] = startedAccount

        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let otherBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        isolatedStateManager.persistStartedTask(
            bookID: otherBook.identifier,
            taskIdentifier: 4_978_010,
            downloadURL: URL(string: "https://library-b.palace-test.invalid/book")!,
            account: otherLibraryID,
            expectedBytes: nil)

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 4_978_011,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        XCTAssertTrue(handler.startedForAccount(for: book, delegate: delegate) === startedAccount,
                      "the record must be selected by the book, not by position")
    }
}
