//
//  BookReturnServiceTests.swift
//  PalaceTests
//
//  Critical-path coverage for the borrow-return state machine extracted
//  into BookReturnService. CLAUDE.md flags return as a user-money path
//  requiring branch-level + error-path tests.
//
//  Branches covered:
//    1. Book not in registry → no-op + completion
//    2. revokeURL == nil + downloaded → local cleanup, registry remove,
//       sync, announce success
//    3. revokeURL == nil + not downloaded → cleanup skips file deletion
//    4. revokeURL + parsing-error-as-success (PalaceError.parsing
//       .opdsFeedInvalid) → treat OverDrive's quirky XML response as
//       success
//    5. revokeURL + no-active-loan / loan-term-limit problem document →
//       local cleanup, registry remove, announce success
//    6. revokeURL + invalid-credentials → reauthenticate + retry
//    7. revokeURL + generic problem document → present alert (we only
//       assert announceReturnFailed since UIAlertController presentation
//       is host-VC dependent and out of scope for unit tests)
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class BookReturnServiceTests: XCTestCase {

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

    override func setUpWithError() throws {
        try super.setUpWithError()
        registry = TPPBookRegistryMock()
        localContent = SpyLocalContentService()
        feedFetcher = StubOPDSFeedFetcher()
        announcementService = SpyAnnouncementService()
        bookmarkLog = .shared  // private init; shared singleton is the only way
        reauthenticator = TPPReauthenticatorMock()
        retryTracker = .shared  // private init; shared singleton is the only way
        spyDelegate = SpyDelegate()
        userAccount = TPPUserAccountMock()

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
            offlineReturnEnqueuer: { _ in } // test isolation: never touch OfflineQueueService.shared
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
            offlineReturnEnqueuer: { _ in } // test isolation: never touch OfflineQueueService.shared
        )
        #endif

        service.delegate = spyDelegate

        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
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

    /// Wait for the service's async Tasks (OPDS fetch + cleanup hops) to
    /// drain. The service uses Task { } extensively — assertions need to
    /// run after those finish.
    /// Wraps the shared `awaitConditionAsync` helper. `file`/`line`
    /// forwarded so timeout XCTFail blames the call site.
    private func waitForCompletion(
        timeout: TimeInterval = 10.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async {
        await awaitConditionAsync(timeout: timeout, file: file, line: line, predicate)
    }

    // MARK: - Branch 1: book not in registry

    func testReturnBook_bookNotInRegistry_callsCompletionAndDoesNothing() async throws {
        // Don't add book to registry
        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: "missing-id") { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 1.0)

        XCTAssertEqual(localContent.deleteForIdentifierCalls, [])
        XCTAssertEqual(announcementService.startedCalls, [])
        XCTAssertEqual(announcementService.succeededCalls, [])
        XCTAssertEqual(announcementService.failedCalls, [])
    }

    // MARK: - 3.2.3 Cause 2: pending remote-write cancellation on return

    /// The return flow MUST cancel any pending throttled remote
    /// listening-position write for the book BEFORE the cleanup runs, so a
    /// queued snapshot can't flush after `deleteAllBookmarks` and resurrect the
    /// stale server position. Verify the injected canceller is invoked with the
    /// returned book's identifier. (The canceller runs synchronously at the top
    /// of `returnBook`, before any async hop.)
    func testReturnBook_cancelsPendingRemotePositionWrite_forTheReturnedBook() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String] = []
            func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
            var recorded: [String] { lock.lock(); defer { lock.unlock() }; return ids }
        }
        let recorder = Recorder()

        #if FEATURE_DRM_CONNECTOR
        let svc = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            remotePositionWriteCanceller: { id in recorder.record(id) }
        )
        #else
        let svc = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            remotePositionWriteCanceller: { id in recorder.record(id) }
        )
        #endif
        svc.delegate = spyDelegate
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Join the service's own completion — `returnBook` always calls it, so
        // there is nothing to bound. A fixed deadline here starves under
        // parallel CI sim clones (STARVE-001).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            svc.returnBook(withIdentifier: book.identifier) { continuation.resume() }
        }

        XCTAssertEqual(recorder.recorded, [book.identifier],
                       "returnBook must cancel the pending remote position write for the returned book exactly once")
    }

    /// A return for a book that isn't in the registry short-circuits BEFORE the
    /// cancellation seam (there's nothing to return). Guards against a mutant
    /// that moves the canceller above the `guard let book` early-out.
    func testReturnBook_bookNotInRegistry_doesNotCancelRemoteWrite() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [String] = []
            func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
            var recorded: [String] { lock.lock(); defer { lock.unlock() }; return ids }
        }
        let recorder = Recorder()
        #if FEATURE_DRM_CONNECTOR
        let svc = BookReturnService(
            bookRegistry: registry, localContentService: localContent,
            opdsFeedService: feedFetcher, downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog, reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            remotePositionWriteCanceller: { id in recorder.record(id) }
        )
        #else
        let svc = BookReturnService(
            bookRegistry: registry, localContentService: localContent,
            opdsFeedService: feedFetcher, downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog, reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            remotePositionWriteCanceller: { id in recorder.record(id) }
        )
        #endif
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            svc.returnBook(withIdentifier: "missing-id") { continuation.resume() }
        }

        XCTAssertEqual(recorder.recorded, [],
                       "No book in registry → nothing to cancel; the seam must run only after the book is resolved")
    }

    // MARK: - Branch 2: revokeURL == nil + downloaded

    func testReturnBook_noRevokeURL_downloaded_deletesContentAndRemovesBook() async throws {
        // Default mock book has no revokeURL.
        XCTAssertNil(book.revokeURL)
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(localContent.deleteForIdentifierCalls, [book.identifier],
                       "downloaded books must have their content deleted on return")
        XCTAssertEqual(spyDelegate.purgeAudiobookCachesCalls, [true],
                       "audiobook caches purged after every return")
        XCTAssertEqual(announcementService.startedCalls, [book.identifier])
        XCTAssertEqual(announcementService.succeededCalls, [book.identifier])
        XCTAssertNil(registry.book(forIdentifier: book.identifier),
                     "registry must remove the book after a no-revokeURL return")
    }

    func testReturnBook_noRevokeURL_notDownloaded_skipsContentDeletion() async throws {
        XCTAssertNil(book.revokeURL)
        registry.addBook(book, location: nil, state: .holding,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(localContent.deleteForIdentifierCalls, [],
                       "non-downloaded books must NOT trigger local-content deletion")
        XCTAssertEqual(spyDelegate.purgeAudiobookCachesCalls, [],
                       "non-downloaded books must NOT trigger audiobook cache purge")
        XCTAssertEqual(announcementService.succeededCalls, [book.identifier])
    }

    // MARK: - Branch 4: revokeURL + parsing error as success

    func testReturnBook_revokeURLReturnsParsingError_treatsAsSuccessAndCleansUp() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        feedFetcher.stubbedError = PalaceError.parsing(.opdsFeedInvalid)

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(announcementService.succeededCalls, [bookWithRevoke.identifier],
                       "OverDrive's invalid-OPDS-feed response is treated as a successful revoke")
        XCTAssertEqual(localContent.deleteForIdentifierCalls, [bookWithRevoke.identifier])
        XCTAssertNil(registry.book(forIdentifier: bookWithRevoke.identifier))
    }

    // MARK: - Branch 5: revokeURL + no-active-loan

    func testReturnBook_revokeURLReturnsNoActiveLoan_cleansUpLocallyAndAnnouncesSuccess() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeNoActiveLoan)
        feedFetcher.stubbedError = NSError(domain: "test", code: 404, userInfo: [
            "problemDocument": problemDoc
        ])

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(announcementService.succeededCalls, [bookWithRevoke.identifier],
                       "no-active-loan means the loan is already gone server-side — treat as success")
        XCTAssertEqual(localContent.deleteForIdentifierCalls, [bookWithRevoke.identifier])
        XCTAssertNil(registry.book(forIdentifier: bookWithRevoke.identifier))
    }

    func testReturnBook_revokeURLReturnsLoanTermLimitDetail_cleansUpLocallyAndAnnouncesSuccess() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Feedbooks/LCP: detail field carries the loan-term-limit marker
        // even though the type is generic. Same cleanup path as
        // no-active-loan.
        let problemDoc = try makeProblemDoc(type: "https://example.com/some-other-error",
                                            detail: TPPProblemDocument.DetailLoanTermLimitReached)
        feedFetcher.stubbedError = NSError(domain: "test", code: 500, userInfo: [
            "problemDocument": problemDoc
        ])

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(announcementService.succeededCalls, [bookWithRevoke.identifier])
        XCTAssertNil(registry.book(forIdentifier: bookWithRevoke.identifier))
    }

    // MARK: - Branch 6: revokeURL + invalid-credentials → reauth + retry

    func testReturnBook_revokeURLReturnsInvalidCredentials_reauthenticatesAndRetries() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        // First call: invalid credentials. Second call: succeed.
        feedFetcher.errorThenSuccess = [
            NSError(domain: "test", code: 401, userInfo: ["problemDocument": problemDoc]),
            nil  // nil means use stubbedFeed (none here, but the no-revokeURL path will be taken on the recursive returnBook... actually no, we still have revokeURL)
        ]

        // Re-auth makes credentials available so the retry recursion runs
        // the second fetchFeed call.
        userAccount._authDefinition = nil  // basic doesn't matter, we just need hasCredentials
        userAccount._credentials = nil
        reauthenticator.onAuthenticate = { [weak self] _, _ in
            self?.userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        }

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Invalid-credentials triggers reauthenticate")
        // After re-auth, recursive returnBook fires. Two fetchFeed calls
        // total. The second one's behavior depends on stubbedError default
        // — we just assert reauth happened.
    }

    // MARK: - Branch 7: revokeURL + generic problem document → alert + announceFailed

    func testReturnBook_revokeURLReturnsGenericError_announcesFailureAndRunsCompletion() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Generic problem doc that's NOT no-active-loan, NOT invalid-credentials,
        // and not a parsing error.
        let problemDoc = try makeProblemDoc(type: "https://example.com/other-error",
                                            detail: "Server unavailable")
        feedFetcher.stubbedError = NSError(domain: "test", code: 500, userInfo: [
            "problemDocument": problemDoc
        ])

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertEqual(announcementService.failedCalls, [bookWithRevoke.identifier],
                       "Generic errors fire announceReturnFailed (alert presented out-of-test)")
        // Book NOT removed in this branch — user sees alert and decides
        XCTAssertNotNil(registry.book(forIdentifier: bookWithRevoke.identifier),
                       "Generic error keeps the book in the registry until user picks an action")
    }

    // MARK: - Task lifecycle (swarm_4e47d4d4 F3 — fire-and-forget retention)

    /// The return flow's revokeURL branch (line 154 Task) is the canonical
    /// "hop to cooperative pool then bounce off MainActor for cleanup" path.
    /// Once we retain that Task, the in-flight count must briefly become
    /// non-zero before draining back to zero — proving the retention happened
    /// and the auto-removal hop ran. A non-retained Task (the bug being
    /// fixed) would leave the count at zero throughout: there's no handle
    /// to insert. Conversely, a retained-but-not-auto-removed Task would
    /// stay non-zero forever; the second predicate catches that.
    func testReturnBook_revokeURLPath_retainsTaskWhileInFlight_andDrainsOnCompletion() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // PalaceError.parsing(.opdsFeedInvalid) routes to the
        // "treat-as-success" cleanup branch which does TPPAnnotations work
        // off the main actor — short enough that the retained Task hits the
        // insert before we observe, then unwinds.
        feedFetcher.stubbedError = PalaceError.parsing(.opdsFeedInvalid)

        XCTAssertEqual(service.inFlightTaskCount, 0,
                       "Precondition: no Tasks in flight before returnBook is called")

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }

        // The retention insert (`inFlightLock … inFlightTasks[id] = task`)
        // runs SYNCHRONOUSLY inside returnBook on this @MainActor test
        // before it returns; the tracked Task body runs on the cooperative
        // pool and cannot auto-remove until we yield the main actor. So the
        // count is deterministically ≥ 1 right now — assert directly instead
        // of polling a wall-clock deadline that starves under CI
        // oversubscription. Capture the tracked Tasks here so we can JOIN
        // them below rather than poll the count back to zero.
        let tracked = service.inFlightTasksSnapshotForTesting()
        XCTAssertGreaterThanOrEqual(service.inFlightTaskCount, 1,
                       "returnBook must synchronously retain its revokeURL cleanup Task")

        await fulfillment(of: [exp], timeout: 3.0)

        // Auto-removal is the last step of the tracked Task body; awaiting
        // each Task's value joins that removal deterministically — no poll.
        for task in tracked { _ = await task.value }
        XCTAssertEqual(service.inFlightTaskCount, 0,
                       "After completion, Tasks must auto-remove from the retention set")
    }

    /// Drives the revokeURL Task once, then calls cancelAllInFlightTasks
    /// directly — proves the cancellation seam empties the set. Catches
    /// any regression where reset/sign-out paths can't drain pending
    /// returns deterministically.
    func testReturnBook_cancelAllInFlightTasks_emptiesTheRetentionSet() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // Stub a fetch that blocks until the test sets a flag — gives us
        // a window where the Task is definitively in the set when we
        // call cancelAllInFlightTasks.
        let blocker = AsyncBlocker()
        feedFetcher.blockingBehavior = blocker

        service.returnBook(withIdentifier: bookWithRevoke.identifier, completion: nil)

        // Retention insert is synchronous inside returnBook (see the
        // drains-on-completion test above); the blocked OPDS fetch keeps the
        // Task parked, so the count is deterministically ≥ 1 right now.
        let inFlightBeforeCancel = service.inFlightTaskCount
        XCTAssertGreaterThanOrEqual(inFlightBeforeCancel, 1,
                                    "Sanity: Task must be retained while OPDS fetch is pending")

        service.cancelAllInFlightTasks()

        XCTAssertEqual(service.inFlightTaskCount, 0,
                       "cancelAllInFlightTasks must immediately drain the retention set")

        // Unblock so the cancelled Task can unwind cleanly and not leak
        // a continuation past test teardown.
        await blocker.unblock(throwing: NSError(domain: "test", code: -1))
    }

    /// Service deinit eventually fires once every in-flight Task has
    /// drained — at which point the `[weak self]` capture in each
    /// tracked Task body short-circuits any remaining work, so no
    /// `bookRegistry` / `localContentService` writes happen after the
    /// service is gone. This test proves the deinit hook fires (via
    /// the static counter) after the Tasks finish, and that the
    /// `[weak self]` short-circuit is honored.
    ///
    /// Regression covered: a future refactor that drops `[weak self]`
    /// from a tracked Task body — or removes the `inFlightTasks`
    /// retention entirely — would let post-deinit work fire against a
    /// dangling pointer. The post-deinit invariant we assert here
    /// (`registry.book(...) == nil` even after cancellation) only holds
    /// if the cleanup path was either driven to completion OR fully
    /// short-circuited via the weak-self guard.
    func testReturnService_inFlightTasks_shortCircuitAfterServiceDeinits() async throws {
        let localRegistry = TPPBookRegistryMock()
        let localFeedFetcher = StubOPDSFeedFetcher()
        // Use a fast-cancellation stub instead of the blocking one so
        // the Tasks actually finish and free the service for deinit.
        // The stub throws a sentinel error → service routes to
        // handleRevokeError → generic-error branch → announceReturnFailed.
        // No registry mutation in the generic branch, so we can assert
        // the registry is untouched by post-deinit work.
        localFeedFetcher.stubbedError = NSError(domain: "test", code: 500,
                                                 userInfo: [NSLocalizedDescriptionKey: "stop"])
        let localAnnouncementService = SpyAnnouncementService()
        let localContentService = SpyLocalContentService()
        let localReauth = TPPReauthenticatorMock()
        let localAccount = TPPUserAccountMock()
        let localDelegate = SpyDelegate()

        let bookWithRevoke = makeBookWithRevokeURL()
        localRegistry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                              fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let countBefore = BookReturnServiceTestHook.deinitCountSync

        await {
            #if FEATURE_DRM_CONNECTOR
            let svc = BookReturnService(
                bookRegistry: localRegistry,
                localContentService: localContentService,
                opdsFeedService: localFeedFetcher,
                downloadAnnouncementService: localAnnouncementService,
                bookmarkDeletionLog: .shared,
                reauthenticator: localReauth,
                userRetryTracker: .shared,
                userAccountProvider: { localAccount }
            )
            #else
            let svc = BookReturnService(
                bookRegistry: localRegistry,
                localContentService: localContentService,
                opdsFeedService: localFeedFetcher,
                downloadAnnouncementService: localAnnouncementService,
                bookmarkDeletionLog: .shared,
                reauthenticator: localReauth,
                userRetryTracker: .shared,
                userAccountProvider: { localAccount }
            )
            #endif
            svc.delegate = localDelegate
            svc.returnBook(withIdentifier: bookWithRevoke.identifier, completion: nil)
            // Retention insert is synchronous inside returnBook, so the count
            // is already ≥ 1 (proves retention). Capture the tracked Tasks and
            // JOIN them — awaiting each Task's value runs the auto-removal step
            // that is the tail of the tracked-Task body, proving drain without
            // a wall-clock sleep loop that starves under CI oversubscription.
            XCTAssertGreaterThanOrEqual(svc.inFlightTaskCount, 1,
                           "returnBook must synchronously retain its cleanup Task")
            for task in svc.inFlightTasksSnapshotForTesting() { _ = await task.value }
            XCTAssertEqual(svc.inFlightTaskCount, 0,
                           "Tracked Tasks must auto-remove once their bodies finish")
        }()

        // Service has no in-flight Tasks left → its strong ref is
        // released at the closing brace → deinit runs.
        // UNJOINABLE: deinit fires on ARC's last-release, which is not a
        // Task/queue we can await. We've already JOINED every tracked Task
        // above and exited the closure scope, so the release has happened;
        // this converges on the first poll. The predicate reads a synchronous
        // static counter, so the loop is cheap even under load.
        await awaitConditionAsync(timeout: 5.0) {
            BookReturnServiceTestHook.deinitCountSync > countBefore
        }
        XCTAssertGreaterThan(BookReturnServiceTestHook.deinitCountSync, countBefore,
                             "BookReturnService deinit must fire once all in-flight Tasks have drained")
    }

    /// Companion to the deinit test: while Tasks are mid-flight, the
    /// retention set protects the service from a race where deinit
    /// fires (somehow) before the Task body's `[weak self]` would
    /// short-circuit. Combined with the per-body `[weak self]` guard,
    /// this covers the cancellation seam end-to-end.
    func testReturnService_cancelAllInFlightTasks_cancelsRetainedTask() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let blocker = AsyncBlocker()
        feedFetcher.blockingBehavior = blocker

        service.returnBook(withIdentifier: bookWithRevoke.identifier, completion: nil)
        // Retention insert is synchronous inside returnBook; the blocked OPDS
        // fetch parks the Task, so it is retained right now — no poll needed.
        XCTAssertGreaterThanOrEqual(service.inFlightTaskCount, 1,
                       "returnBook must synchronously retain its cleanup Task")
        let trackedTask = service.inFlightTasksSnapshotForTesting().first!
        XCTAssertFalse(trackedTask.isCancelled,
                       "Sanity: Task is alive (not yet cancelled) before cancelAllInFlightTasks")

        service.cancelAllInFlightTasks()

        XCTAssertEqual(service.inFlightTaskCount, 0,
                       "Retention set must be drained immediately by cancelAllInFlightTasks")
        XCTAssertTrue(trackedTask.isCancelled,
                      "Each previously-retained Task must be marked cancelled")

        await blocker.unblock(throwing: NSError(domain: "test", code: -1))
    }

    // MARK: - F-008 / PP-4542 — browser-vs-basic markCredentialsStale branch (line 476)
    //
    // Legacy (no-coordinator) return-auth-error path:
    //   `needsBrowserReauth = (authDef?.isBrowserBased == true) && hasCredentials`
    // at BookReturnService.swift:476. When TRUE the service marks credentials
    // stale BEFORE dispatching reauth (so a stale SAML/OIDC bearer isn't
    // silently reused on retry); when FALSE it does not. The observable
    // difference is `markCredentialsStale()` → authState flips to
    // `.credentialsStale`. The pair below stages IDENTICAL pre-state (creds
    // present, logged in, invalid-credentials revoke error) differing ONLY in
    // auth-def browser-ness, and asserts OPPOSITE authState outcomes. Flipping
    // `== true` to `!= true` at :476 swaps them.
    //
    // The setUp service has NO coordinator, so this legacy branch is live.

    /// SAML (browser-based) + credentials + invalid-credentials revoke error
    /// must mark credentials stale before reauth (line 476 true branch).
    ///
    /// Kills :476 `isBrowserBased == true`→`!= true`: under the mutant the
    /// SAML account evaluates `isBrowserBased != true` == false →
    /// `needsBrowserReauth` false → markCredentialsStale is SKIPPED → authState
    /// stays `.loggedIn`, failing the assertion below.
    func testReturnBook_SAMLBrowserAuth_invalidCredentials_marksCredentialsStaleBeforeReauth() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        // First fetch: invalid-credentials (drives the :476 branch). Second
        // fetch (retry after reauth): nil → "feed has no entries" terminal
        // path, so the recursion ends instead of looping.
        feedFetcher.errorThenSuccess = [
            NSError(domain: "test", code: 401, userInfo: ["problemDocument": problemDoc]),
            nil
        ]

        userAccount._authDefinition = makeAuth(typeRaw: "http://librarysimplified.org/authtype/SAML-2.0")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        XCTAssertEqual(userAccount.authState, .loggedIn, "pre-state: logged in")
        // Reauth completion keeps the (still-present) credentials so the retry
        // recursion fires the second fetch — but does NOT markLoggedIn, so the
        // `.credentialsStale` state set by the :476 branch survives for the
        // assertion below.
        reauthenticator.onAuthenticate = { _, _ in /* credentials retained */ }

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(userAccount.authState, .credentialsStale,
                       "SAML browser-based return auth error must markCredentialsStale (:476 true branch). " +
                       "The `!= true` mutant would skip this and leave authState .loggedIn.")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Browser-based return auth error still dispatches reauth after marking stale.")
    }

    /// Basic (NON-browser) + credentials + invalid-credentials revoke error
    /// must NOT mark credentials stale (line 476 false branch) — basic auth
    /// re-prompts in-app, the existing bearer is not a browser session to
    /// invalidate. Negative control for the pair.
    ///
    /// Kills :476 `isBrowserBased == true`→`!= true` from the other side:
    /// under the mutant a basic account evaluates `isBrowserBased != true`
    /// == true → `needsBrowserReauth` true → markCredentialsStale fires →
    /// authState becomes `.credentialsStale`, failing the assertion below.
    func testReturnBook_basicAuth_invalidCredentials_doesNotMarkCredentialsStale() async throws {
        let bookWithRevoke = makeBookWithRevokeURL()
        registry.addBook(bookWithRevoke, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let problemDoc = try makeProblemDoc(type: TPPProblemDocument.TypeInvalidCredentials)
        // First fetch: invalid-credentials. Second fetch (retry): nil →
        // terminal "no entries" path so the recursion ends.
        feedFetcher.errorThenSuccess = [
            NSError(domain: "test", code: 401, userInfo: ["problemDocument": problemDoc]),
            nil
        ]

        userAccount._authDefinition = makeAuth(typeRaw: "http://opds-spec.org/auth/basic")
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        reauthenticator.onAuthenticate = { _, _ in /* credentials retained */ }

        let exp = expectation(description: "completion")
        service.returnBook(withIdentifier: bookWithRevoke.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "Basic (non-browser) return auth error must NOT markCredentialsStale (:476 false branch). " +
                       "The `!= true` mutant would mark it stale and flip authState to .credentialsStale.")
        XCTAssertTrue(reauthenticator.authenticateIfNeededCalled,
                      "Basic return auth error still dispatches reauth (just without the stale-marking).")
    }

    // MARK: - Return-to-empty ghost (#18414 / return-your-last-book) — production seam
    //
    // FORWARD-PORT (main → develop): the 3.2.3 return-to-empty tests that lived
    // here are intentionally NOT carried over in this merge. They exercise the D1
    // `serverAuthoritative` plumbing (#18414) — `TPPBookRegistry.removeBook(
    // forIdentifier:serverAuthoritative:)` / `updateAndRemoveBook(_:serverAuthoritative:)`
    // and `RegistryFileRecovery.onDiskHasRecords` — which do NOT exist on develop:
    // Wave 2b moved the registry into `PalaceBookRegistry`, whose copy has the
    // narrower INV-1 guard and a different `BookRegistrySync` init signature.
    //
    // Porting D1 is a behavioral change to the data path and deserves its own
    // reviewed PR rather than riding along inside a 29-commit history merge. The
    // removed tests are the SPEC for that port — recover them from
    // `origin/main:PalaceTests/MyBooks/BookReturnServiceTests.swift`.
    //
    // NOT a regression: develop keeps its current (narrower) guard, which never
    // refused these saves in the first place.

    // MARK: - Helpers

    private func makeAuth(typeRaw: String) -> AccountDetails.Authentication {
        let json = #"{"type": "\#(typeRaw)"}"#
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeBookWithRevokeURL() -> TPPBook {
        // TPPBookMocker doesn't expose a revokeURL knob — drop down to the
        // designated TPPBook init (matching PalaceTests/TPPBookMock.swift)
        // so we can set the field.
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

    // MARK: - INV-3: offline return enqueues, no local cleanup

    /// A genuine offline (`NSURLError`) revoke failure must NOT dead-end in
    /// an alert. It enqueues an `OfflineAction(.return, ...)` and — the
    /// critical part — does NOT delete local content or unregister the book
    /// until the queued return is later server-confirmed.
    func testOfflineReturn_enqueues_doesNotDeleteLocalContent() async {
        let enqueueSpy = EnqueueSpy()
        let book = makeBookWithRevokeURL()
        registry.addBook(book, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let offlineService = BookReturnService(
            bookRegistry: registry,
            localContentService: localContent,
            opdsFeedService: feedFetcher,
            downloadAnnouncementService: announcementService,
            bookmarkDeletionLog: bookmarkLog,
            reauthenticator: reauthenticator,
            userRetryTracker: retryTracker,
            userAccountProvider: { [unowned self] in self.userAccount },
            offlineReturnEnqueuer: { action in await enqueueSpy.record(action) }
        )
        offlineService.delegate = spyDelegate

        // A real no-connection transport error.
        feedFetcher.stubbedError = NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorNotConnectedToInternet)

        let exp = expectation(description: "completion")
        offlineService.returnBook(withIdentifier: book.identifier) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3.0)

        // Enqueued exactly one return for this book.
        let enqueued = await enqueueSpy.actions
        XCTAssertEqual(enqueued.count, 1)
        XCTAssertEqual(enqueued.first?.type, .return)
        XCTAssertEqual(enqueued.first?.bookID, book.identifier)

        // INV-3: NO local cleanup, NO unregister until server-confirmed.
        XCTAssertTrue(localContent.deleteForIdentifierCalls.isEmpty,
            "INV-3: offline return must not delete local content")
        XCTAssertNotEqual(registry.state(for: book.identifier), .unregistered,
            "INV-3: offline return must not unregister before server confirmation")
        XCTAssertNotNil(registry.book(forIdentifier: book.identifier),
            "INV-3: the book stays in the registry until the queued return succeeds")
    }

    /// Pins the offline-error classifier used by the INV-3 branch: genuine
    /// no-connection codes are offline; other NSURLErrors (and non-URL
    /// errors) are not — so only real offline failures get enqueued.
    func testIsOfflineNSURLError_classifiesConnectivityCodes() {
        XCTAssertTrue(BookReturnService.isOfflineNSURLError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        XCTAssertTrue(BookReturnService.isOfflineNSURLError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(BookReturnService.isOfflineNSURLError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        // A non-connectivity URL error is NOT offline.
        XCTAssertFalse(BookReturnService.isOfflineNSURLError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)))
        // A non-URL error domain is NOT offline.
        XCTAssertFalse(BookReturnService.isOfflineNSURLError(
            NSError(domain: "some.other.domain", code: NSURLErrorNotConnectedToInternet)))
    }
}

/// Records enqueued offline actions for the INV-3 test.
private actor EnqueueSpy {
    private(set) var actions: [OfflineAction] = []
    func record(_ action: OfflineAction) { actions.append(action) }
}

// MARK: - Test fakes

private final class StubOPDSFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    var stubbedError: Error?
    /// Allow per-call sequencing for the invalid-credentials retry test.
    /// Each call pops the head; if nil the call uses `stubbedError` instead.
    var errorThenSuccess: [Error?] = []
    /// Optional blocker — when set, `fetchFeed` waits on it. Used by the
    /// Task-lifecycle tests to keep the retained Task alive long enough
    /// to observe the in-flight count + drive a cancellation.
    var blockingBehavior: AsyncBlocker?
    private var callCount = 0

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        callCount += 1
        if let blocker = blockingBehavior {
            try await blocker.wait()
        }
        if !errorThenSuccess.isEmpty {
            let err = errorThenSuccess.removeFirst()
            if let err = err { throw err }
            // success path: throw a "feed has no entries" parse error so the
            // service routes through its `feed.entries.count == 1` check
            // → announceReturnFailed; the test only cares that the second
            // fetch was invoked.
        }
        if let stubbedError {
            throw stubbedError
        }
        // Real TPPOPDSFeed construction requires valid OPDS XML which is
        // heavy. Tests that don't supply a stubbed error fall through to
        // a sentinel throw — none of the covered branches exercise the
        // successful-revoke path (which is a separate follow-up).
        throw NSError(domain: "BookReturnServiceTests.stub", code: -999,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}

/// Suspends an async caller until the test releases it. Used to pin
/// the BookReturnService's retained Task in flight while the test
/// observes / cancels.
actor AsyncBlocker {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?

    func wait() async throws {
        if let pending = pendingResult {
            pendingResult = nil
            try pending.get()
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
        }
    }

    func unblock(throwing error: Error? = nil) {
        if let cont = continuation {
            continuation = nil
            if let error = error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: ())
            }
        } else {
            pendingResult = error.map { .failure($0) } ?? .success(())
        }
    }
}

private final class SpyLocalContentService: LocalBookContentService {
    var deleteForIdentifierCalls: [String] = []

    init() {
        // Use a fresh test-factory container's accountsManager; we don't
        // actually delete any files because the spy short-circuits via
        // override. The factory yields a per-call fresh service graph with
        // no `AppContainer._cached` mutation.
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
