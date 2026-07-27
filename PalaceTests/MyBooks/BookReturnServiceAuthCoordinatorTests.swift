//
//  BookReturnServiceAuthCoordinatorTests.swift
//  PalaceTests
//
//  swarm_66819d80 Module C — caller-migration assertions at the
//  `BookReturnService` SEAM. Pins that when the service is constructed
//  WITH a non-nil `authCoordinator`, the auth-error branch routes
//  through the coordinator (NOT the legacy `reauthenticator` closure).
//
//  Reviewer-fixup (QA-3, swarm_66819d80 Pass 3): the original test class
//  never instantiated `BookReturnService` — all 3 tests hit the
//  coordinator directly and duplicated `AuthCoordinatorTests` coverage.
//  The service's coordinator-routing branch was unverified at the
//  service seam. This rewrite instantiates the real `BookReturnService`
//  with spy collaborators, drives a return that triggers the auth-error
//  branch (401 with invalid-credentials problem-doc), and asserts the
//  coordinator IS invoked while the legacy reauthenticator is NOT.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAuth
import PalaceBookModel

@MainActor
final class BookReturnServiceAuthCoordinatorTests: XCTestCase {

    private var registry: TPPBookRegistryMock!
    private var localContent: SpyLocalContentService!
    private var feedFetcher: StubOPDSFeedFetcher!
    private var announcementService: SpyAnnouncementService!
    private var bookmarkLog: TPPBookmarkDeletionLog!
    private var reauthenticator: TPPReauthenticatorMock!
    private var retryTracker: UserRetryTracker!
    private var spyDelegate: SpyDelegate!
    private var userAccount: TPPUserAccountMock!
    private var service: BookReturnService!
    private var book: TPPBook!

    private func makeService(coordinator: AuthCoordinator?) {
        #if FEATURE_DRM_CONNECTOR
        service = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        #else
        service = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            authCoordinator: coordinator
        )
        #endif
        service.delegate = spyDelegate
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        localContent = SpyLocalContentService()
        feedFetcher = StubOPDSFeedFetcher()
        announcementService = SpyAnnouncementService()
        bookmarkLog = .shared
        reauthenticator = TPPReauthenticatorMock()
        retryTracker = .shared
        spyDelegate = SpyDelegate()
        userAccount = TPPUserAccountMock()
        book = makeBookWithRevokeURL()
    }

    override func tearDownWithError() throws {
        registry = nil
        localContent = nil
        feedFetcher = nil
        announcementService = nil
        bookmarkLog = nil
        reauthenticator = nil
        retryTracker = nil
        spyDelegate = nil
        userAccount = nil
        service = nil
        book = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeProblemDoc(type: String? = nil, detail: String? = nil) throws -> TPPProblemDocument {
        var dict: [String: Any] = [:]
        if let type { dict["type"] = type }
        if let detail { dict["detail"] = detail }
        if dict.isEmpty { dict["title"] = "x" }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
    }

    nonisolated private func makeBookWithRevokeURL() -> TPPBook {
        let identifier = "rev-\(UUID().uuidString)"
        let acquisitionURL = URL(string: "http://example.com/\(identifier)")!
        let revokeURL = URL(string: "http://example.com/\(identifier)/revoke")!
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: acquisitionURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "a", relatedBooksURL: nil)],
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Test",
            updated: Date(),
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

    // MARK: - QA-3 fix: drive the SERVICE seam, not the coordinator directly

    /// Construct a real `BookReturnService` WITH an injected coordinator
    /// + drive a return that hits the auth-error branch. Asserts that the
    /// service routes through `coordinator.refreshCredentialsIfNeeded`
    /// (modal fires) and does NOT fall through to the legacy
    /// `reauthenticator.authenticateIfNeeded` closure.
    ///
    /// Uses `stubModalResult: false` (user cancels modal) so the failure
    /// path terminates the recursion — modal-success retries the return
    /// which would re-enter the auth-error branch with the same stubbed
    /// fetchFeed failure, looping forever. The cancellation path is the
    /// observable end-state we can pin without orchestrating a
    /// fetchFeed sequence.
    ///
    /// Pins the production-graph seam: the `if let coordinator = ...`
    /// branch at `BookReturnService.handleRevokeError` is the contract
    /// that the migration depends on. Without this test, the migration
    /// could regress to "coordinator constructed but never called" and
    /// no other test would catch it (the coordinator-only tests live in
    /// PalaceAuthTests and don't touch the service).
    func testService_authErrorOnReturn_withCoordinatorWired_routesThroughCoordinator_notLegacyReauthenticator() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .token,
            stubReauthResult: false,
            stubModalResult: false   // user cancels → coordinator failure terminates the chain
        )
        makeService(coordinator: coordinator)

        // Add book to registry so the service doesn't short-circuit.
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Stub the revoke fetch to return an invalid-credentials 401 so
        // the service's `isAuthError` predicate fires.
        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        feedFetcher.stubbedError = NSError(
            domain: "test",
            code: 401,
            userInfo: ["problemDocument": problemDoc]
        )

        // Drive the return. Completion fires when the service finishes
        // the initial pass — the coordinator dispatch happens in a
        // detached Task, so we still need to wait for the modal call.
        let exp = expectation(description: "return completion")
        exp.assertForOverFulfill = false
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        // The coordinator dispatch is a tracked Task whose body awaits
        // `refreshCredentialsIfNeeded` (which increments `presentCallCount`)
        // BEFORE it calls `completion?()`. So when the completion fulfils this
        // expectation, the modal has already been presented — JOIN on the
        // completion, then assert directly. No wall-clock poll (which starves
        // under CI oversubscription and is redundant here).
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(modal.presentCallCount, 1,
                       "Service must route the auth-error branch through coordinator.refreshCredentialsIfNeeded EXACTLY once — modal NOT invoked means the `if let coordinator` branch was skipped")
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Legacy reauthenticator.authenticateIfNeeded MUST NOT fire when coordinator is wired — that branch is the test-only fallback for callers that pass authCoordinator: nil")
    }

    /// When the coordinator is NOT injected (nil), the service falls back
    /// to the legacy `reauthenticator` closure path. Pins the symmetry:
    /// existing tests that don't pass a coordinator still get the legacy
    /// recovery behavior. Without this pin, a refactor that removes the
    /// legacy fallback would silently break every pre-coordinator test
    /// surface and we'd have no targeted assertion to point at.
    func testService_authErrorOnReturn_withoutCoordinator_fallsBackToLegacyReauthenticator() async throws {
        makeService(coordinator: nil)

        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        feedFetcher.stubbedError = NSError(
            domain: "test",
            code: 401,
            userInfo: ["problemDocument": problemDoc]
        )

        let exp = expectation(description: "return completion")
        exp.assertForOverFulfill = false
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        // The legacy fallback runs in a tracked MainActor Task that CALLS
        // `reauthenticator.authenticateIfNeeded` (setting the flag) and only
        // fires `completion?()` from inside that reauth callback. So when this
        // expectation is fulfilled, the flag is already set — JOIN on the
        // completion and assert directly, no wall-clock poll.
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Without coordinator wiring, the service MUST fall back to the legacy reauthenticator — fallback removal without a coordinator injected would silently break recovery")
    }

    /// When the coordinator returns `.failure(.userCancelled)`, the service
    /// must announce return failure (so the UI clears the spinner) and
    /// MUST NOT retry the return — re-entry would loop indefinitely on
    /// a persistent auth error.
    func testService_coordinatorCancellation_announcesReturnFailed_andDoesNotRetry() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(
            mechanism: .saml,             // SAML always routes through modal
            stubModalResult: false        // user cancels
        )
        makeService(coordinator: coordinator)

        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        feedFetcher.stubbedError = NSError(
            domain: "test",
            code: 401,
            userInfo: ["problemDocument": problemDoc]
        )

        let exp = expectation(description: "return completion (cancellation path)")
        exp.assertForOverFulfill = false
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        // On cancellation the tracked coordinator Task presents the modal,
        // then in a single `runOnMainAsync` block calls `announceReturnFailed`
        // immediately before `completion?()`. So when this expectation is
        // fulfilled, BOTH the modal-present and the failed-announcement have
        // already happened — JOIN on the completion, assert directly. No poll,
        // no fixed settle sleep.
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(modal.presentCallCount, 1,
                       "Coordinator must be dispatched once on the auth-error branch")
        XCTAssertTrue(announcementService.failedCalls.contains(book.identifier),
                      "Coordinator cancellation must propagate as announceReturnFailed so the UI spinner clears")
        // The service must NOT retry the return after cancellation
        // (that would loop on the same auth error).
        XCTAssertFalse(reauthenticator.authenticateIfNeededCalled,
                       "Legacy reauthenticator MUST NOT fire when coordinator handled the auth error")
    }
}

// MARK: - Test fakes (mirror BookReturnServiceTests' pattern)

private final class StubOPDSFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    var stubbedError: Error?
    private var callCount = 0

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        callCount += 1
        if let stubbedError {
            throw stubbedError
        }
        throw NSError(domain: "BookReturnServiceAuthCoordinatorTests.stub", code: -999,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}

private final class SpyLocalContentService: LocalBookContentService {
    var deleteForIdentifierCalls: [String] = []

    init() {
        // Use a fresh test-factory container's accountsManager; spy short-
        // circuits real file deletion via the deleteLocalContent overrides.
        super.init(
            bookRegistry: TPPBookRegistryMock(),
            accountsManager: makeTestAppContainer().accountsManager,
            bookFileManager: BookFileManager(bookRegistry: TPPBookRegistryMock()),
            fileManager: .default
        )
    }

    override func deleteLocalContent(for identifier: String, account: String? = nil) {
        deleteForIdentifierCalls.append(identifier)
    }

    override func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
        deleteForIdentifierCalls.append(book.identifier)
    }
}

private final class SpyAnnouncementService: DownloadAnnouncementService {
    var startedCalls: [String] = []
    var succeededCalls: [String] = []
    var failedCalls: [String] = []

    override func announceReturnStarted(for book: TPPBook) {
        startedCalls.append(book.identifier)
    }

    override func announceReturnSucceeded(for book: TPPBook) {
        succeededCalls.append(book.identifier)
    }

    override func announceReturnFailed(for book: TPPBook) {
        failedCalls.append(book.identifier)
    }
}

private final class SpyDelegate: BookReturnServiceDelegate {
    var purgeAudiobookCachesCalls: [Bool] = []

    func purgeAllAudiobookCaches(force: Bool) {
        purgeAudiobookCachesCalls.append(force)
    }
}
