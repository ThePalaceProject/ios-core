//
//  ReaderBookmarkSyncGateTests.swift
//  PalaceTests
//
//  Bookmark sync when sync is off: the sync must finish with the local list,
//  without a request or a re-authentication attempt, and with sync on the
//  upload-then-merge flow and the stale-credential retry are unchanged.
//

import XCTest
@preconcurrency import ReadiumShared
import PalaceBookModel
import PalaceCatalog
@testable import Palace

@MainActor
final class ReaderBookmarkSyncGateTests: XCTestCase {

    private let annotationsURL = URL(string: "https://test.library.org/annotations/")!
    private let bookID = "urn:uuid:sync-gate-book"

    private var registry: TPPBookRegistryMock!
    private var accounts: TPPLibraryAccountMock!
    private var patron: TPPUserAccountMock!
    private var reauthenticator: TPPReauthenticatorMock!
    private var logic: TPPReaderBookmarksBusinessLogic!
    private var syncPermissionRestore: (() -> Void)?
    private var trackedWindow: UIWindow?

    override func setUp() {
        super.setUp()
        MockAnnotationsURLProtocol.reset()
        registry = TPPBookRegistryMock()
        accounts = TPPLibraryAccountMock()
        patron = TPPUserAccountMock()
        let patron = self.patron!
        accounts.userAccountResolver = { _ in patron }
        reauthenticator = TPPReauthenticatorMock()

        let book = Self.makeBook(identifier: bookID, annotationsURL: annotationsURL)
        registry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockAnnotationsURLProtocol.self]
        TPPAnnotations.executorOverride = TPPNetworkExecutor(credentialsProvider: nil,
                                                             cachingStrategy: .ephemeral,
                                                             sessionConfiguration: config,
                                                             accountsManager: accounts)
        TPPAnnotations.accountsManagerOverride = accounts
        TPPAnnotations.annotationsURLOverride = annotationsURL

        logic = TPPReaderBookmarksBusinessLogic(book: book,
                                                r2Publication: Publication(manifest: Manifest(metadata: Metadata(title: "Sync gate"))),
                                                drmDeviceID: "this-device",
                                                bookRegistryProvider: registry,
                                                currentLibraryAccountProvider: accounts,
                                                reauthenticator: reauthenticator)
    }

    override func tearDown() {
        if let window = trackedWindow {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.rootViewController?.dismiss(animated: false, completion: nil)
            window.isHidden = true
            window.rootViewController = nil
            window.resignKey()
            trackedWindow = nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        TPPAnnotations.executorOverride = nil
        TPPAnnotations.accountsManagerOverride = nil
        TPPAnnotations.annotationsURLOverride = nil
        MockAnnotationsURLProtocol.reset()
        syncPermissionRestore?()
        syncPermissionRestore = nil
        logic = nil
        reauthenticator = nil
        patron = nil
        accounts = nil
        registry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// `syncPermissionGranted` writes through to UserDefaults, so the
    /// pre-test value is restored in tearDown.
    private func configurePatron(signedIn: Bool, syncPermitted: Bool, staleCredentials: Bool = false) {
        if signedIn {
            patron._credentials = .token(authToken: "tok", barcode: "12345", pin: "1234",
                                         expirationDate: Date().addingTimeInterval(3600))
        }
        if staleCredentials { patron.markCredentialsStale() }
        if syncPermissionRestore == nil, let details = accounts.currentAccount?.details {
            let previous = details.syncPermissionGranted
            syncPermissionRestore = { details.syncPermissionGranted = previous }
        }
        accounts.currentAccount?.details?.syncPermissionGranted = syncPermitted
    }

    private func addLocalBookmark(annotationId: String?, href: String) -> TPPReadiumBookmark {
        let bookmark = TPPReadiumBookmark(annotationId: annotationId, href: href, chapter: "Chapter",
                                          page: nil, location: nil,
                                          progressWithinChapter: 0.5, progressWithinBook: 0.25,
                                          readingOrderItem: nil, readingOrderItemOffsetMilliseconds: 0,
                                          time: "2026-01-01T00:00:00Z", device: "this-device")!
        registry.add(bookmark, forIdentifier: bookID)
        return bookmark
    }

    private struct SyncResult {
        let calls: Int
        let success: Bool?
        let bookmarks: [TPPReadiumBookmark]
    }

    /// Runs one sync and keeps the main run loop going a little after the
    /// first callback, so a second callback would be counted.
    private func syncAndWait(timeout: TimeInterval = 5) -> SyncResult {
        var calls = 0
        var success: Bool?
        var bookmarks: [TPPReadiumBookmark] = []
        let completed = expectation(description: "syncBookmarks completion")
        logic.syncBookmarks { ok, list in
            calls += 1
            success = ok
            bookmarks = list
            if calls == 1 { completed.fulfill() }
        }
        wait(for: [completed], timeout: timeout)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return SyncResult(calls: calls, success: success, bookmarks: bookmarks)
    }

    // MARK: - Sync off

    /// A signed-out patron's sync finishes once with the local list and sends nothing.
    func testSyncBookmarks_WhenSignedOut_CompletesOnceWithLocalBookmarksAndNoRequest() {
        configurePatron(signedIn: false, syncPermitted: true)
        let local = addLocalBookmark(annotationId: nil, href: "/one.html")

        let result = syncAndWait()

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(result.bookmarks.map(\.href), [local.href])
        XCTAssertEqual(logic.bookmarks.map(\.href), [local.href])
        XCTAssertTrue(MockAnnotationsURLProtocol.capturedRequests.isEmpty)
    }

    /// A patron who turned sync off must not be sent through re-authentication
    /// on book open just because their session expired.
    func testSyncBookmarks_WhenSyncTurnedOffWithStaleCredentials_DoesNotReauthenticate() {
        configurePatron(signedIn: true, syncPermitted: false, staleCredentials: true)
        XCTAssertEqual(patron.authState, .credentialsStale)
        let local = addLocalBookmark(annotationId: nil, href: "/one.html")

        let result = syncAndWait()

        XCTAssertEqual(reauthenticator.authenticateCallCount, 0)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(result.bookmarks.map(\.href), [local.href])
        XCTAssertTrue(MockAnnotationsURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Sync on (unchanged behaviour)

    /// Book open with sync on: unsynced bookmarks are posted first, then the
    /// server list is merged, and the sync reports success.
    func testSyncBookmarks_WhenSyncOn_UploadsThenMergesServerBookmarks() throws {
        configurePatron(signedIn: true, syncPermitted: true)
        _ = addLocalBookmark(annotationId: nil, href: "/one.html")
        let uploadedID = "https://test.library.org/annotations/uploaded"
        let otherDeviceID = "https://test.library.org/annotations/other-device"
        let getBody = AnnotationsTestFixtures.serverBookmarksResponse(bookmarks: [
            AnnotationsTestFixtures.createServerBookmark(annotationId: uploadedID, bookId: bookID,
                                                         href: "/one.html", device: "this-device"),
            AnnotationsTestFixtures.createServerBookmark(annotationId: otherDeviceID, bookId: bookID,
                                                         href: "/two.html", device: "another-device")
        ])
        let postBody = try JSONSerialization.data(withJSONObject: [
            TPPBookmarkSpec.Id.key: uploadedID,
            TPPBookmarkSpec.Body.key: [TPPBookmarkSpec.Body.Time.key: "2026-01-01T00:00:01Z"]
        ])
        MockAnnotationsURLProtocol.requestHandler = { request in
            let body = request.httpMethod == "POST" ? postBody : getBody
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let result = syncAndWait()

        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.success, true)
        XCTAssertEqual(Set(result.bookmarks.compactMap(\.annotationId)), [uploadedID, otherDeviceID])
        XCTAssertEqual(MockAnnotationsURLProtocol.capturedRequests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(reauthenticator.authenticateCallCount, 0)
    }

    /// With sync on, a failed fetch for a patron whose session expired still
    /// tries re-authentication once, using the account the sync gate checked.
    func testSyncBookmarks_WhenSyncOnAndFetchFailsWithStaleCredentials_Reauthenticates() {
        configurePatron(signedIn: true, syncPermitted: true, staleCredentials: true)
        MockAnnotationsURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
        }

        let result = syncAndWait()

        XCTAssertEqual(reauthenticator.authenticateCallCount, 1)
        XCTAssertEqual(result.calls, 1)
        XCTAssertEqual(result.success, false)
    }

    // MARK: - Pull to refresh

    /// If sync stops being possible after the refresh control was installed,
    /// pulling to refresh must still stop the spinner.
    func testPullToRefresh_WhenSyncBecameImpossible_EndsRefreshing() throws {
        configurePatron(signedIn: true, syncPermitted: true)
        let delegate = SyncForwardingDelegate(logic: logic)
        let vc = TPPReaderPositionsVC.newInstance()
        vc.bookmarksBusinessLogic = logic
        vc.delegate = delegate
        // A refresh control only starts refreshing on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        trackedWindow = window
        vc.loadViewIfNeeded()
        vc.segmentedControl.selectedSegmentIndex = 1
        vc.didSelectSegment(vc.segmentedControl)
        let refresh = try XCTUnwrap(vc.tableView.subviews.compactMap { $0 as? UIRefreshControl }.first,
                                    "the bookmarks tab installs a refresh control while sync is possible")

        patron._credentials = nil
        refresh.beginRefreshing()
        XCTAssertTrue(refresh.isRefreshing)
        refresh.sendActions(for: .valueChanged)

        let deadline = Date().addingTimeInterval(5)
        while refresh.isRefreshing && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertEqual(delegate.syncRequests, 1)
        XCTAssertTrue(MockAnnotationsURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Fixtures

    private static func makeBook(identifier: String, annotationsURL: URL) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(relation: .generic, type: "application/epub+zip",
                                             hrefURL: URL(string: "https://test.example.com/book")!,
                                             indirectAcquisitions: [],
                                             availability: TPPOPDSAcquisitionAvailabilityUnlimited())
        return TPPBook(acquisitions: [acquisition], authors: [], categoryStrings: [], distributor: "",
                       identifier: identifier, imageURL: nil, imageThumbnailURL: nil, published: Date(),
                       publisher: "", subtitle: "", summary: "", title: "Sync gate", updated: Date(),
                       annotationsURL: annotationsURL, analyticsURL: nil, alternateURL: nil,
                       relatedWorksURL: nil, previewLink: nil, seriesURL: nil, revokeURL: nil,
                       reportURL: nil, timeTrackingURL: nil, contributors: [:], bookDuration: nil,
                       imageCache: MockImageCache())
    }
}

/// Forwards the positions screen's sync request to the business logic, the
/// way `TPPBaseReaderViewController` does.
private final class SyncForwardingDelegate: TPPReaderPositionsDelegate {
    private let logic: TPPReaderBookmarksBusinessLogic
    private(set) var syncRequests = 0
    init(logic: TPPReaderBookmarksBusinessLogic) { self.logic = logic }

    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectTOCLocation loc: Any) {}
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectBookmark bookmark: TPPReadiumBookmark) {}
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didDeleteBookmark bookmark: TPPReadiumBookmark) {}
    func positionsVC(_ positionsVC: TPPReaderPositionsVC,
                     didRequestSyncBookmarksWithCompletion completion: @escaping (Bool, [TPPReadiumBookmark]) -> Void) {
        syncRequests += 1
        logic.syncBookmarks(completion: completion)
    }
    func positionsVC(_ positionsVC: TPPReaderPositionsVC, didSelectPageLocation location: Any, pageLabel: String) {}
}
