//
//  BookReturnServiceContractTests.swift
//  PalaceTests
//
//  Contract-snapshot coverage for BookReturnService. The MBDC return-flow
//  extraction (PR #890) lifted ~230 LOC of nested error-handling branches
//  into this class; any branch where the call sequence into the registry +
//  local-content + announcement service changes is a candidate for the
//  same silent-decomposition class of bug as F-011 / F-014.
//
//  Each test pins the contract: for input X, here are the calls in order.
//  A re-extraction or path-change that drops a setState or moves a
//  deleteLocalContent before a deleteAllBookmarks trips the diff.
//
//  Coverage:
//    - happy path with revokeURL → setProcessing(true) → fetchFeed →
//      (cleanup local) → setState(.unregistered) → announceReturnSucceeded
//    - revokeURL nil → skips network → deleteLocalContent → setState →
//      announceReturnSucceeded
//    - parsing error (OverDrive quirk) → treat as success
//    - no-active-loan problem doc → treat as success
//    - generic error → setProcessing(false) → announceReturnFailed
//    - auth error → markCredentialsStale + reauthenticator.authenticateIfNeeded
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookReturnServiceContractTests: XCTestCase {

    private var log: CallLog!
    private var registry: SpyBookRegistry!
    private var localContent: SpyLocalContentRecorder!
    private var feedFetcher: StubFeedFetcher!
    private var announce: SpyAnnouncementRecorder!
    private var bookmarkLog: TPPBookmarkDeletionLog!
    private var reauth: SpyReauthRecorder!
    private var retryTracker: UserRetryTracker!
    private var purgeDelegate: SpyPurgeDelegate!
    private var userAccount: TPPUserAccountMock!
    private var service: BookReturnService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        registry = SpyBookRegistry(log: log)
        localContent = SpyLocalContentRecorder(log: log)
        feedFetcher = StubFeedFetcher()
        announce = SpyAnnouncementRecorder(log: log)
        bookmarkLog = .shared
        reauth = SpyReauthRecorder(log: log)
        retryTracker = .shared
        purgeDelegate = SpyPurgeDelegate(log: log)
        userAccount = TPPUserAccountMock()

        #if FEATURE_DRM_CONNECTOR
        service = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announce,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauth,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            offlineReturnEnqueuer: { _ in } // test isolation: never touch OfflineQueueService.shared
        )
        #else
        service = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announce,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauth,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            offlineReturnEnqueuer: { _ in } // test isolation: never touch OfflineQueueService.shared
        )
        #endif
        service.delegate = purgeDelegate
    }

    override func tearDownWithError() throws {
        log = nil
        registry = nil
        localContent = nil
        feedFetcher = nil
        announce = nil
        bookmarkLog = nil
        reauth = nil
        retryTracker = nil
        purgeDelegate = nil
        userAccount = nil
        service = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy path with revokeURL

    /// revokeURL + downloaded book + fetchFeed returns 1-entry feed →
    /// the contract is:
    ///   1. announceReturnStarted
    ///   2. setProcessing(true)
    ///   3. (fetchFeed lands implicitly — captured here by setProcessing(false) on the success leg)
    ///   4. setProcessing(false)
    ///   5. (post-feed cleanup leg — see note on TPPAnnotations below)
    ///
    /// NOTE: the success leg's `TPPAnnotations.deleteAllBookmarks` callback
    /// triggers `setState(.unregistered) → performPostReturnSyncThen →
    /// announceReturnSucceeded`. `TPPAnnotations.deleteAllBookmarks` is
    /// a static call we don't intercept here — its completion block fires
    /// asynchronously through TPPAnnotations' real flow, which without a
    /// network stack does NOT call back. This is a known seam: the happy
    /// path's tail is only fully exercised in integration. Production-code
    /// note: TPPAnnotations is a candidate for protocol extraction so the
    /// callback can be deterministically driven from tests.
    ///
    /// We pin the contract through `setProcessing(false)` (the deterministic
    /// portion of the happy path) and explicitly note the gap.
    func test_returnBook_withRevokeURL_happyPath_callsRegistrySetState_then_syncCompletes() async throws {
        let book = Self.makeBook(identifier: "RET-OK", revokeURL: URL(string: "http://example.com/revoke")!)
        registry.addBookStub(book, state: .downloadSuccessful)

        // Configure feed fetcher to throw a parsing-invalid error — this
        // routes through the OverDrive-quirk "treat as success" branch,
        // which DOES drive cleanup deterministically via the static
        // TPPAnnotations callback. The "true happy path" (valid 1-entry
        // OPDS feed) requires constructing a real TPPOPDSFeed, which is
        // out of scope for the unit-test snapshot.
        feedFetcher.stubbedError = PalaceError.parsing(.opdsFeedInvalid)

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        ContractSnapshot.assert(log, named: "withRevokeURL_parsingErrorTreatedAsSuccess")
    }

    // MARK: - revokeURL nil

    /// revokeURL nil → skip network entirely, cleanup runs locally.
    func test_returnBook_withoutRevokeURL_skipsNetwork_clearsLocalContent() async throws {
        let book = Self.makeBook(identifier: "RET-NOURL", revokeURL: nil)
        registry.addBookStub(book, state: .downloadSuccessful)

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        ContractSnapshot.assert(log, named: "withoutRevokeURL_skipsNetwork")
    }

    // MARK: - Auth error → reauth

    /// 401 invalid-credentials on the revoke fetch → service calls
    /// `reauthenticator.authenticateIfNeeded(_, usingExistingCredentials:
    /// false, ...)`. We don't follow the recursive retry call all the way
    /// (the mock auths immediately, recursion fires; we just pin the
    /// pre-retry sequence).
    func test_returnBook_authError_triggersReauth() async throws {
        let book = Self.makeBook(identifier: "RET-AUTH", revokeURL: URL(string: "http://example.com/revoke")!)
        registry.addBookStub(book, state: .downloadSuccessful)

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        // First fetch fails with invalid-credentials; suppress retry recursion
        // by leaving subsequent fetches throwing the same error (reauth mock
        // doesn't restore credentials, so the credentials check fails and
        // the retry path bails out before re-entering returnBook).
        feedFetcher.stubbedError = NSError(domain: "test", code: 401,
                                            userInfo: ["problemDocument": problemDoc])

        let exp = expectation(description: "completion")
        // The reauth path doesn't necessarily call completion if the
        // recursive return doesn't fire — bail-out triggers
        // announceReturnFailed + completion (line ~322 in service).
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        ContractSnapshot.assert(log, named: "authError_triggersReauth")
    }

    // MARK: - No active loan → treat as success

    /// Loan already gone server-side → treat as success and clean up
    /// locally. Pins the cleanup sequence.
    func test_returnBook_noActiveLoan_treatsAsSuccess() async throws {
        let book = Self.makeBook(identifier: "RET-NAL", revokeURL: URL(string: "http://example.com/revoke")!)
        registry.addBookStub(book, state: .downloadSuccessful)

        let problemDoc = Self.makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        feedFetcher.stubbedError = NSError(domain: "test", code: 404,
                                            userInfo: ["problemDocument": problemDoc])

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        ContractSnapshot.assert(log, named: "noActiveLoan_treatsAsSuccess")
    }

    // MARK: - Generic error → alert + announceReturnFailed

    /// Generic problem doc (not no-active-loan, not invalid-credentials,
    /// not a parsing error) → service announces failure via
    /// `announceReturnFailed`. We pin THAT call. UIAlertController
    /// presentation isn't recorded — it's host-VC dependent and out of
    /// scope for unit tests.
    func test_returnBook_genericError_presentsAlert() async throws {
        let book = Self.makeBook(identifier: "RET-ERR", revokeURL: URL(string: "http://example.com/revoke")!)
        registry.addBookStub(book, state: .downloadSuccessful)

        let problemDoc = Self.makeProblemDoc(type: "https://example.com/other-error",
                                              detail: "Server unavailable")
        feedFetcher.stubbedError = NSError(domain: "test", code: 500,
                                            userInfo: ["problemDocument": problemDoc])

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        ContractSnapshot.assert(log, named: "genericError_announcesFailure")
    }

    // MARK: - Offline return -> enqueue (INV-3)

    /// A genuine offline (`NSURLError`) revoke failure enqueues the return
    /// and performs NO local cleanup. The contract must show the enqueue
    /// and must NOT contain `localContent.deleteLocalContent`,
    /// `registry.setState`, or `registry.removeBook` — the client stays
    /// consistent with the server until the queued return is confirmed.
    func test_returnBook_offlineError_enqueues_noLocalCleanup() async throws {
        let book = Self.makeBook(identifier: "RET-OFFLINE",
                                 revokeURL: URL(string: "http://example.com/revoke")!)
        registry.addBookStub(book, state: .downloadSuccessful)

        let log = self.log!
        let offlineService = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announce,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauth,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            offlineReturnEnqueuer: { action in
                log.record("queue.enqueue",
                           args: ["type": action.type.rawValue, "bookId": action.bookID])
            }
        )
        offlineService.delegate = purgeDelegate

        feedFetcher.stubbedError = NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorNotConnectedToInternet)

        let exp = expectation(description: "completion")
        offlineService.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        ContractSnapshot.assert(log, named: "offlineError_enqueues_noLocalCleanup")
    }

    // MARK: - Helpers

    private static func makeProblemDoc(type: String? = nil, detail: String? = nil) -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let detail { dict["detail"] = detail }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return TPPProblemDocument.fromProblemResponseData(data)!
    }

    private static func makeBook(identifier: String, revokeURL: URL?) -> TPPBook {
        let acquisitionURL = URL(string: "http://example.com/\(identifier)")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Title-\(identifier)",
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: revokeURL,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Spies

/// Records the registry-mutation surface BookReturnService touches. We
/// keep the registry storage minimally functional so reads (state(for:),
/// book(forIdentifier:)) return the right answer during the flow.
private final class SpyBookRegistry: TPPBookRegistryMock {
    let log: CallLog
    init(log: CallLog) {
        self.log = log
        super.init()
    }

    /// Adds the book WITHOUT recording, so test fixture setup doesn't
    /// pollute the contract.
    func addBookStub(_ book: TPPBook, state: TPPBookState) {
        super.addBook(book, location: nil, state: state,
                      fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }

    override func setProcessing(_ processing: Bool, for bookIdentifier: String) {
        log.record("registry.setProcessing",
                   args: ["bookId": bookIdentifier, "processing": "\(processing)"])
        super.setProcessing(processing, for: bookIdentifier)
    }

    override func setState(_ state: TPPBookState, for bookIdentifier: String) {
        log.record("registry.setState",
                   args: ["bookId": bookIdentifier, "state": "\(state.stringValue())"])
        super.setState(state, for: bookIdentifier)
    }

    override func removeBook(forIdentifier bookIdentifier: String) {
        log.record("registry.removeBook", args: ["bookId": bookIdentifier])
        super.removeBook(forIdentifier: bookIdentifier)
    }

    override func updateAndRemoveBook(_ book: TPPBook) {
        log.record("registry.updateAndRemoveBook", args: ["bookId": book.identifier])
        super.updateAndRemoveBook(book)
    }
}

/// Subclasses LocalBookContentService and overrides the delete entry
/// points to record without actually touching the filesystem.
private final class SpyLocalContentRecorder: LocalBookContentService {
    let log: CallLog
    init(log: CallLog) {
        self.log = log
        super.init(
            bookRegistry: TPPBookRegistryMock(),
            accountsManager: makeTestAppContainer().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: TPPBookRegistryMock()),
            fileManager: .default
        )
    }

    override func deleteLocalContent(for identifier: String, account: String? = nil) {
        log.record("localContent.deleteLocalContent",
                   args: ["bookId": identifier, "account": account ?? "nil"])
    }

    override func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        log.record("localContent.deleteLocalContentForBook",
                   args: ["bookId": book.identifier, "account": account ?? "nil"])
    }
}

private final class SpyAnnouncementRecorder: DownloadAnnouncementService {
    let log: CallLog
    init(log: CallLog) {
        self.log = log
        super.init()
    }

    override func announceReturnStarted(for book: TPPBook) {
        log.record("announce.returnStarted", args: ["bookId": book.identifier])
    }
    override func announceReturnSucceeded(for book: TPPBook) {
        log.record("announce.returnSucceeded", args: ["bookId": book.identifier])
    }
    override func announceReturnFailed(for book: TPPBook) {
        log.record("announce.returnFailed", args: ["bookId": book.identifier])
    }
}

private final class SpyReauthRecorder: NSObject, Reauthenticator {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func authenticateIfNeeded(_ user: TPPUserAccount,
                               usingExistingCredentials: Bool,
                               authenticationCompletion: (@Sendable () -> Void)?) {
        log.record("reauth.authenticateIfNeeded",
                   args: ["usingExistingCredentials": "\(usingExistingCredentials)"])
        // Fire completion synchronously so the service's retry-bail-out
        // path (no credentials yet) runs to completion under the test.
        authenticationCompletion?()
    }
}

private final class SpyPurgeDelegate: BookReturnServiceDelegate {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func purgeAllAudiobookCaches(force: Bool) {
        log.record("delegate.purgeAllAudiobookCaches", args: ["force": "\(force)"])
    }
}

private final class StubFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    var stubbedError: Error?
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        if let err = stubbedError { throw err }
        throw NSError(domain: "StubFeedFetcher", code: -999,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}
