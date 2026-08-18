//
//  CrossDeviceSyncE2ETests.swift
//  PalaceTests
//
//  In-process round-trip tests simulating two devices on the same patron
//  account. Writes from "device A" go through a real TPPNetworkExecutor and
//  the real TPPAnnotations code path, land in a shared MockSyncBackend, and
//  are read back via a second TPPNetworkExecutor representing "device B".
//
//  The five scenarios:
//   1. EPUB locator round-trip (reading-progress motivation)
//   2. LocatorAudioBookTime round-trip (reading-progress motivation)
//   3. Bookmark added on A, visible on B
//   4. Bookmark deleted on A, gone on B
//   5. Server-wins conflict resolution
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import ReadiumShared
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class CrossDeviceSyncE2ETests: XCTestCase {

    // MARK: - Test fixtures

    private static let deviceA = "urn:uuid:device-A-cross-device-e2e"
    private static let deviceB = "urn:uuid:device-B-cross-device-e2e"
    private static let bookID = "urn:uuid:cross-device-e2e-book"
    private static let baseURL = URL(string: "https://mock.library.test/annotations/")!

    private var backend: MockSyncBackend!
    private var libraryAccount: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!
    private var executorA: TPPNetworkExecutor!
    private var executorB: TPPNetworkExecutor!
    /// Device A with no connectivity: NoNetworkURLProtocol answers every
    /// request with NSURLErrorNotConnectedToInternet, which is in
    /// NetworkQueue.StatusCodes and therefore queueable (PP-4965).
    private var executorAOffline: TPPNetworkExecutor!

    private var savedExecutorOverride: TPPNetworkExecutor?
    private var savedAccountsOverride: TPPLibraryAccountsProvider?
    private var savedDeviceAccountsOverride: TPPUserAccountResolving?
    private var savedFirebaseDeviceOverride: String?
    private var savedAnnotationsURLOverride: URL?

    // MARK: - Setup / teardown

    override func setUp() {
        super.setUp()

        // Save existing override state — restored in tearDown so we don't
        // pollute neighbouring suites that also touch these statics.
        savedExecutorOverride = TPPAnnotations.executorOverride
        savedAccountsOverride = TPPAnnotations.accountsManagerOverride
        savedDeviceAccountsOverride = AnnotationDevice.accountsManagerOverride
        savedFirebaseDeviceOverride = AnnotationDevice.firebaseDeviceIDOverride
        savedAnnotationsURLOverride = TPPAnnotations.annotationsURLOverride

        // Reset shared user-account state so credential writes here don't
        // leak across tests.
        TPPUserAccountMock.resetShared()

        backend = MockSyncBackend(baseURL: Self.baseURL)

        // Register the backend handler. HTTPStubURLProtocol intercepts
        // every request via canInit -> true, so we MUST scope to the
        // annotation URL prefix or we'll swallow unrelated traffic.
        HTTPStubURLProtocol.reset()
        let backendRef = backend!
        HTTPStubURLProtocol.register { request in
            return backendRef.handle(request)
        }

        // Library account mock loads NYPL auth doc which advertises
        // supportsSimplyESync = true → gates the sync-permission check
        // so TPPAnnotations code paths actually run.
        libraryAccount = TPPLibraryAccountMock()

        // Shared user account ("same patron"). Both device executors see it.
        userAccount = TPPUserAccountMock()
        userAccount._credentials = .token(
            authToken: "test-bearer",
            barcode: "12345",
            pin: "1234",
            expirationDate: Date().addingTimeInterval(3600)
        )
        userAccount.markLoggedIn()

        // Replace the library account's resolver so currentUserAccount
        // returns our credentialed mock. Capture directly to avoid IUO
        // nil-unwrap when a stale URLSession callback fires after tearDown.
        let resolvedUserAccount = userAccount!
        libraryAccount.userAccountResolver = { _ in resolvedUserAccount }

        // Both devices use the same URLSession configuration with
        // HTTPStubURLProtocol — they both end up talking to backend.
        let configA = URLSessionConfiguration.ephemeral
        configA.protocolClasses = [HTTPStubURLProtocol.self]
        executorA = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: configA
        )

        let configB = URLSessionConfiguration.ephemeral
        configB.protocolClasses = [HTTPStubURLProtocol.self]
        executorB = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: configB
        )

        let configOffline = URLSessionConfiguration.ephemeral
        configOffline.protocolClasses = [NoNetworkURLProtocol.self]
        executorAOffline = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: configOffline
        )

        // Install the shared library/accounts override now so any read
        // through TPPAnnotations sees a sync-supporting library.
        TPPAnnotations.accountsManagerOverride = libraryAccount
        AnnotationDevice.accountsManagerOverride = libraryAccount

        // Pin the annotations URL to the mock backend. Production reads
        // TPPConfiguration.mainFeedURL() which is nil on CI's clean runner
        // (no signed-in library defaults), so without this override every
        // POST/GET path early-returns before hitting HTTPStubURLProtocol.
        TPPAnnotations.annotationsURLOverride = Self.baseURL
    }

    override func tearDown() {
        // Always restore the prior override state — never `nil` here, since
        // another suite might have legitimately set these (the executor
        // override seam doc says to reset, but tests run in arbitrary
        // order under random ordering and we want to be a good citizen).
        TPPAnnotations.executorOverride = savedExecutorOverride
        TPPAnnotations.accountsManagerOverride = savedAccountsOverride
        AnnotationDevice.accountsManagerOverride = savedDeviceAccountsOverride
        AnnotationDevice.firebaseDeviceIDOverride = savedFirebaseDeviceOverride
        TPPAnnotations.annotationsURLOverride = savedAnnotationsURLOverride

        HTTPStubURLProtocol.reset()
        backend?.clear()
        backend = nil
        executorA = nil
        executorB = nil
        libraryAccount = nil
        userAccount = nil
        super.tearDown()
    }

    // MARK: - Per-device seam helpers

    /// Run `block` with the device-A executor + device-A annotation device
    /// ID active. Restores prior state on exit.
    ///
    /// The "current device ID" surface area in TPPAnnotations is split:
    ///   - `AnnotationDevice.currentID()` reads `_deviceID` from the user
    ///     account when present, else the Firebase override.
    ///   - `postReadingPosition` reads `currentUserAccount.deviceID` directly
    ///     (the Adobe-DRM path), NOT `AnnotationDevice.currentID()`.
    /// We push the device tag into the user account here so both code paths
    /// see the same value. Both A and B share the same TPPUserAccount (same
    /// patron), so the test treats the deviceID field as the per-write
    /// "which device am I" stamp.
    private func asDeviceA<T>(_ block: () throws -> T) rethrows -> T {
        let prevExec = TPPAnnotations.executorOverride
        let prevDev = AnnotationDevice.firebaseDeviceIDOverride
        let prevAccountDeviceID = userAccount.deviceID
        TPPAnnotations.executorOverride = executorA
        AnnotationDevice.firebaseDeviceIDOverride = Self.deviceA
        userAccount.setDeviceID(Self.deviceA)
        defer {
            TPPAnnotations.executorOverride = prevExec
            AnnotationDevice.firebaseDeviceIDOverride = prevDev
            if let prev = prevAccountDeviceID {
                userAccount.setDeviceID(prev)
            }
        }
        return try block()
    }

    /// Device A, but with no connectivity. Same device tag as `asDeviceA`, so
    /// anything that *does* reach the backend is still attributable to A.
    private func asDeviceAOffline<T>(_ block: () throws -> T) rethrows -> T {
        let prevExec = TPPAnnotations.executorOverride
        let prevDev = AnnotationDevice.firebaseDeviceIDOverride
        let prevAccountDeviceID = userAccount.deviceID
        TPPAnnotations.executorOverride = executorAOffline
        AnnotationDevice.firebaseDeviceIDOverride = Self.deviceA
        userAccount.setDeviceID(Self.deviceA)
        defer {
            TPPAnnotations.executorOverride = prevExec
            AnnotationDevice.firebaseDeviceIDOverride = prevDev
            if let prev = prevAccountDeviceID {
                userAccount.setDeviceID(prev)
            }
        }
        return try block()
    }

    private func asDeviceB<T>(_ block: () throws -> T) rethrows -> T {
        let prevExec = TPPAnnotations.executorOverride
        let prevDev = AnnotationDevice.firebaseDeviceIDOverride
        let prevAccountDeviceID = userAccount.deviceID
        TPPAnnotations.executorOverride = executorB
        AnnotationDevice.firebaseDeviceIDOverride = Self.deviceB
        userAccount.setDeviceID(Self.deviceB)
        defer {
            TPPAnnotations.executorOverride = prevExec
            AnnotationDevice.firebaseDeviceIDOverride = prevDev
            if let prev = prevAccountDeviceID {
                userAccount.setDeviceID(prev)
            }
        }
        return try block()
    }

    /// Activates device A's stubbed executor + device tag and returns a closure
    /// that restores the prior override state.
    ///
    /// Unlike `asDeviceA`, this does NOT auto-restore on scope exit. It exists
    /// for the fire-and-forget return-cleanup path: `deleteAllBookmarks` issues
    /// a GET synchronously, then re-reads `TPPAnnotations.executorOverride` at
    /// DELETE time inside the GET's *async* completion — long after the
    /// synchronous call returns. `asDeviceA`'s `defer` restores the override
    /// before those DELETEs fire, so they route through
    /// `AppContainer.production().networkExecutor` (blocked by
    /// `NoNetworkURLProtocol`, error -1003) instead of the mock backend, and
    /// the annotations are never actually deleted. The caller must hold the
    /// returned restore closure across the whole async chain + poll window and
    /// invoke it only once the deletions have settled.
    private func holdDeviceAExecutor() -> () -> Void {
        let prevExec = TPPAnnotations.executorOverride
        let prevDev = AnnotationDevice.firebaseDeviceIDOverride
        let prevAccountDeviceID = userAccount.deviceID
        TPPAnnotations.executorOverride = executorA
        AnnotationDevice.firebaseDeviceIDOverride = Self.deviceA
        userAccount.setDeviceID(Self.deviceA)
        return { [weak self] in
            TPPAnnotations.executorOverride = prevExec
            AnnotationDevice.firebaseDeviceIDOverride = prevDev
            if let prev = prevAccountDeviceID {
                self?.userAccount?.setDeviceID(prev)
            }
        }
    }

    // MARK: - Helpers: locators / books / sync gate verification

    private func epubSelectorValue(href: String,
                                   progressInChapter: Double,
                                   progressInBook: Double,
                                   title: String) -> String {
        let dict: [String: Any] = [
            "@type": "LocatorHrefProgression",
            "href": href,
            "progressWithinChapter": progressInChapter,
            "progressWithinBook": progressInBook,
            "title": title
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }

    private func audiobookSelectorValue(readingOrderItem: String,
                                        offsetMilliseconds: Int,
                                        chapter: String) -> String {
        // NOTE: `"annotationId": ""` is deliberate and load-bearing. Every
        // listening position Palace POSTs embeds an EMPTY annotationId
        // (`AudioBookmark.encode` writes the field unconditionally; a fresh
        // local position has no server id yet), so this is the real shape of
        // the bytes on the server.
        //
        // Omitting the key made this fixture diverge from production and hid a
        // shipped bug: with the key absent, `AudioBookmark.create`'s
        // `locatorData["annotationId"] as? String ?? annotationId` fell through
        // to the real server id and the return-cleanup DELETE was issued, so
        // the test passed. In production the empty string won, the parsed
        // bookmark had no server linkage, and the listening position was never
        // deleted — resurrecting on re-borrow (HelpSpot #18468 / #18019 /
        // #18449). Keep this key here so the fixture can fail.
        let dict: [String: Any] = [
            "@type": "LocatorAudioBookTime",
            "@version": 2,
            "annotationId": "",
            "readingOrderItem": readingOrderItem,
            "readingOrderItemOffsetMilliseconds": offsetMilliseconds,
            "chapter": chapter
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }

    private func makeBook(audiobook: Bool = false) -> TPPBook {
        let mediaType = audiobook ? "application/audiobook+json" : "application/epub+zip"
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: mediaType,
            hrefURL: URL(string: "https://test.example.com/book")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: Self.bookID,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "Cross-Device E2E Book",
            updated: Date(),
            annotationsURL: Self.baseURL,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// If the production sync gate is closed for any reason in this test
    /// environment (no auth doc loaded, no credentials, etc.), the
    /// TPPAnnotations static methods early-return without touching the
    /// network. We skip rather than report a misleading pass.
    // MARK: - PP-4965: what an offline device does to the other device

    /// Device A loses connectivity. Its position write is handed to the offline
    /// queue, so nothing reaches the server and device B correctly sees
    /// nothing — but A must NOT report this as an error. Reporting it is what
    /// made "Error posting annotation" the largest error in the app while the
    /// writes themselves were fine.
    func test_positionWrittenWhileDeviceAOffline_isInvisibleToB_andNotReportedAsAnError() async throws {
        try skipIfSyncGateClosed()

        let spy = ErrorLoggerSpy()
        TPPAnnotations.errorLoggerOverride = spy
        defer { TPPAnnotations.errorLoggerOverride = nil }

        let selectorValue = epubSelectorValue(
            href: "/chapter9.xhtml",
            progressInChapter: 0.9,
            progressInBook: 0.5,
            title: "Chapter 9"
        )
        let postsBefore = backend.postCount

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            asDeviceAOffline {
                TPPAnnotations.postReadingPosition(
                    forBook: Self.bookID,
                    selectorValue: selectorValue,
                    motivation: .readingProgress
                ) { _ in cont.resume() }
            }
        }

        XCTAssertEqual(backend.postCount, postsBefore,
                       "An offline write must never reach the server")
        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 0,
                       "Backend must hold nothing after an offline write")
        // PP-4987: today this write is NOT queued, so reporting it is correct.
        //
        // The networking layer discards the underlying transport error when no
        // HTTP response arrives — the offline case — and substitutes a generic
        // "invalid or no HTTP response" code. `postAnnotation` decides
        // queue-worthiness by matching the error against a list of NSURLError
        // conditions, and the generic code is not on it, so the offline queue
        // never receives the write. It is lost, and an error is the honest
        // report.
        //
        // Expressed as an expected failure rather than by asserting the broken
        // behaviour: when PP-4987 lands, this stops failing, XCTest flags the
        // unfulfilled expectation, and whoever fixed it flips the assertion to
        // the correct one below. Asserting the defect directly is how the
        // pre-PP-4965 suite pinned a bug as a contract.
        XCTExpectFailure("PP-4987: transport error is discarded, so the write is never queued and is correctly reported. Delete this expectation when PP-4987 lands.") {
            XCTAssertEqual(spy.loggedSummaries, [],
                           "Once offline writes are actually queued, a queued write must not be reported as an error")
        }
        XCTAssertEqual(spy.firstReportedNSError?.code,
                       TPPErrorCode.invalidOrNoHTTPResponse.rawValue,
                       "Documents the PP-4987 mechanism: the offline reason is replaced by a generic no-response code")

        // B sees nothing, and that is correct: the write was never delivered.
        let book = makeBook()
        let seenByB: BookmarkListProjection =
            await withCheckedContinuation { (cont: CheckedContinuation<BookmarkListProjection, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .readingProgress
                    ) { bookmarks in
                        cont.resume(returning: BookmarkListProjection(bookmarks))
                    }
                }
            }
        XCTAssertEqual(seenByB.count, 0,
                       "Device B must not see a position that was never delivered")
    }

    /// The same position, written once A is back online, does reach B. This is
    /// what makes the case above a delay rather than a loss.
    ///
    /// Note this re-posts directly rather than draining `TPPNetworkQueue` —
    /// the queue's own retry behaviour is its responsibility and is covered by
    /// its own suite. What is asserted here is the cross-device consequence:
    /// an offline write followed by a connected write leaves B holding exactly
    /// one annotation, A's, not two and not zero.
    func test_positionRewrittenAfterDeviceAReconnects_reachesDeviceB() async throws {
        try skipIfSyncGateClosed()

        let selectorValue = epubSelectorValue(
            href: "/chapter9.xhtml",
            progressInChapter: 0.9,
            progressInBook: 0.5,
            title: "Chapter 9"
        )

        // Offline attempt — goes nowhere.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            asDeviceAOffline {
                TPPAnnotations.postReadingPosition(
                    forBook: Self.bookID,
                    selectorValue: selectorValue,
                    motivation: .readingProgress
                ) { _ in cont.resume() }
            }
        }
        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 0,
                       "Precondition: the offline attempt must not have reached the server")

        // Reconnected attempt — lands.
        let hasServerId: Bool =
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                asDeviceA {
                    TPPAnnotations.postReadingPosition(
                        forBook: Self.bookID,
                        selectorValue: selectorValue,
                        motivation: .readingProgress
                    ) { response in cont.resume(returning: response?.serverId != nil) }
                }
            }
        XCTAssertTrue(hasServerId, "The reconnected write must be accepted by the server")

        let book = makeBook()
        let seenByB: BookmarkListProjection =
            await withCheckedContinuation { (cont: CheckedContinuation<BookmarkListProjection, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .readingProgress
                    ) { bookmarks in
                        cont.resume(returning: BookmarkListProjection(bookmarks))
                    }
                }
            }
        XCTAssertEqual(seenByB.count, 1,
                       "B must end up with exactly one annotation — the offline attempt must not have left a duplicate")
        XCTAssertEqual(seenByB.first?.device, Self.deviceA,
                       "The delivered annotation must still be tagged to device A")
    }

    private func skipIfSyncGateClosed() throws {
        guard TPPAnnotations.syncIsPossibleAndPermitted() else {
            throw XCTSkip("Sync gate closed in this environment (no credentials / library auth doc) — skipping E2E sync test")
        }
    }

    // MARK: - Test 1: EPUB locator round-trip

    /// Device A writes a reading-progress annotation for an EPUB locator;
    /// device B retrieves it via the same shared backend. Verifies the full
    /// POST→GET protocol exchange, including device-tagging.
    func test_positionWrittenOnDeviceA_readableOnDeviceB() async throws {
        try skipIfSyncGateClosed()

        let selectorValue = epubSelectorValue(
            href: "/chapter3.xhtml",
            progressInChapter: 0.42,
            progressInBook: 0.21,
            title: "Chapter 3"
        )

        // A writes (the real TPPAnnotations.postListeningPosition wraps
        // postReadingPosition with motivation=.readingProgress and includes
        // device=Self.deviceA derived from AnnotationDevice.currentID()).
        // JOIN on the completion: AnnotationResponse is non-Sendable, so we
        // project the two Sendable facts the assertions need (response
        // presence + server-ID presence) inside the completion.
        let postResult: (hasResponse: Bool, hasServerId: Bool) =
            await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Bool), Never>) in
                asDeviceA {
                    TPPAnnotations.postReadingPosition(
                        forBook: Self.bookID,
                        selectorValue: selectorValue,
                        motivation: .readingProgress
                    ) { response in
                        cont.resume(returning: (response != nil, response?.serverId != nil))
                    }
                }
            }
        XCTAssertTrue(postResult.hasResponse, "Device A's POST should return an AnnotationResponse with a server ID")
        XCTAssertTrue(postResult.hasServerId, "Server must assign an annotation ID")

        // Verify the backend captured exactly one annotation tagged for device A.
        let stored = backend.allAnnotations(forBook: Self.bookID)
        XCTAssertEqual(stored.count, 1, "Backend must hold one annotation after A's POST")
        XCTAssertEqual(stored.first?.motivation,
                       TPPBookmarkSpec.Motivation.readingProgress.rawValue,
                       "Stored annotation must carry reading-progress motivation")
        XCTAssertEqual(stored.first?.selectorValue, selectorValue,
                       "Selector value must be preserved verbatim through the POST")

        // B reads — same backend, but a different executor + a different
        // device ID. The reading-progress bookmark must come back parsed.
        // JOIN on the completion: TPPReadiumBookmark is non-Sendable, so we
        // project the Sendable facts the assertions check (type match + the
        // four preserved fields) inside the completion.
        let book = makeBook()
        let readBack: ReadiumBookmarkProjection? =
            await withCheckedContinuation { (cont: CheckedContinuation<ReadiumBookmarkProjection?, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .readingProgress
                    ) { bookmarks in
                        cont.resume(returning: ReadiumBookmarkProjection(bookmarks?.first))
                    }
                }
            }

        let readiumBookmark = try XCTUnwrap(readBack,
                                            "B must receive the same annotation as a TPPReadiumBookmark")
        XCTAssertEqual(readiumBookmark.href, "/chapter3.xhtml",
                       "Round-tripped bookmark must preserve href")
        XCTAssertEqual(readiumBookmark.progressWithinChapter, 0.42, accuracy: 0.001,
                       "Round-tripped bookmark must preserve chapter progression")
        XCTAssertEqual(readiumBookmark.progressWithinBook, 0.21, accuracy: 0.001,
                       "Round-tripped bookmark must preserve book progression")
        XCTAssertEqual(readiumBookmark.device, Self.deviceA,
                       "Annotation must remain tagged with device A — B's read must not stamp B's ID")
    }

    // MARK: - Test 2: Audiobook locator round-trip

    /// Same flow as #1 but with `LocatorAudioBookTime` payload. The factory
    /// must recognize the audiobook locator type and return an
    /// `AudioBookmark`, not a `TPPReadiumBookmark`.
    func test_audiobookPositionOnDeviceA_readableOnDeviceB() async throws {
        try skipIfSyncGateClosed()

        let selectorValue = audiobookSelectorValue(
            readingOrderItem: "track-7.mp3",
            offsetMilliseconds: 123_456,
            chapter: "Chapter 7"
        )

        // Set device A seam manually around the async call (async closures
        // can't ferry the `defer` cleanly through asDeviceA, so we inline).
        let prevExec = TPPAnnotations.executorOverride
        let prevDev = AnnotationDevice.firebaseDeviceIDOverride
        let prevAccountID = userAccount.deviceID
        TPPAnnotations.executorOverride = executorA
        AnnotationDevice.firebaseDeviceIDOverride = Self.deviceA
        userAccount.setDeviceID(Self.deviceA)
        do {
            _ = try await TPPAnnotations.postAudiobookBookmark(
                forBook: Self.bookID,
                selectorValue: selectorValue
            )
        } catch {
            TPPAnnotations.executorOverride = prevExec
            AnnotationDevice.firebaseDeviceIDOverride = prevDev
            if let prev = prevAccountID { userAccount.setDeviceID(prev) }
            XCTFail("Device A's audiobook POST must not throw: \(error)")
            return
        }
        TPPAnnotations.executorOverride = prevExec
        AnnotationDevice.firebaseDeviceIDOverride = prevDev
        if let prev = prevAccountID { userAccount.setDeviceID(prev) }

        // Verify the backend captured exactly one bookmark-motivation
        // annotation. `postAudiobookBookmark` uses motivation=.bookmark per
        // TPPAnnotations.swift.
        let stored = backend.allAnnotations(forBook: Self.bookID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.motivation,
                       TPPBookmarkSpec.Motivation.bookmark.rawValue)

        // B reads as an audiobook — the factory should hand back an
        // `AudioBookmark`, not a Readium one. JOIN on the completion:
        // AudioBookmark is non-Sendable, so we project the Sendable facts the
        // assertions check (type match + the two round-tripped fields) inside
        // the completion.
        let book = makeBook(audiobook: true)
        let readBack: AudioBookmarkProjection? =
            await withCheckedContinuation { (cont: CheckedContinuation<AudioBookmarkProjection?, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .bookmark
                    ) { bookmarks in
                        cont.resume(returning: AudioBookmarkProjection(bookmarks?.first))
                    }
                }
            }

        let audio = try XCTUnwrap(readBack,
                                  "B must receive the audiobook locator as an AudioBookmark")
        XCTAssertEqual(audio.readingOrderItem, "track-7.mp3",
                       "Audiobook reading-order item must round-trip")
        XCTAssertEqual(audio.readingOrderItemOffsetMilliseconds, 123_456,
                       "Audiobook offset must round-trip")
    }

    // MARK: - Test 3: Bookmark added on A, visible on B

    /// User-initiated bookmark (motivation=.bookmark) on device A is fetched
    /// via the normal getServerBookmarks path on device B.
    func test_bookmarkAddedOnDeviceA_visibleOnDeviceB() async throws {
        try skipIfSyncGateClosed()

        let selectorValue = epubSelectorValue(
            href: "/chapter5.xhtml",
            progressInChapter: 0.10,
            progressInBook: 0.55,
            title: "Chapter 5"
        )

        // A creates a bookmark via the same code path the reader uses.
        let local = try XCTUnwrap(TPPReadiumBookmark(
            annotationId: nil,
            href: "/chapter5.xhtml",
            chapter: "Chapter 5",
            page: nil,
            location: selectorValue,
            progressWithinChapter: 0.10,
            progressWithinBook: 0.55,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: ISO8601DateFormatter().string(from: Date()),
            device: Self.deviceA
        ))

        // JOIN on the POST completion. serverId is a String? (Sendable), so we
        // resume with it directly.
        let serverID: String? =
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                asDeviceA {
                    TPPAnnotations.postBookmark(local, forBookID: Self.bookID) { response in
                        cont.resume(returning: response?.serverId)
                    }
                }
            }

        XCTAssertNotNil(serverID, "Server must return an annotation ID for the new bookmark")
        let storedAfterPost = backend.allAnnotations(forBook: Self.bookID)
        XCTAssertEqual(storedAfterPost.count, 1, "Backend must hold A's new bookmark")
        XCTAssertEqual(storedAfterPost.first?.motivation,
                       TPPBookmarkSpec.Motivation.bookmark.rawValue,
                       "Stored annotation must carry bookmark motivation")

        // B reads the bookmark list — it must include A's bookmark and the
        // factory must surface it with the server-assigned annotation ID.
        // JOIN on the completion: the [Bookmark] list is non-Sendable, so we
        // project the Sendable facts (list nil-ness, count, and the first
        // element's Readium projection) inside the completion.
        let book = makeBook()
        let readResult: BookmarkListProjection =
            await withCheckedContinuation { (cont: CheckedContinuation<BookmarkListProjection, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .bookmark
                    ) { bookmarks in
                        cont.resume(returning: BookmarkListProjection(bookmarks))
                    }
                }
            }

        XCTAssertTrue(readResult.wasNonNil, "B's GET must return a non-nil bookmark list")
        XCTAssertEqual(readResult.count, 1, "B should see exactly the bookmark A wrote")
        let bookmark = try XCTUnwrap(readResult.first,
                                     "B's first bookmark must be a TPPReadiumBookmark")
        XCTAssertEqual(bookmark.annotationId, serverID,
                       "B's view of A's bookmark must carry the server-assigned annotation ID")
        // TPPBookLocation normalizes /chapter5.xhtml → chapter5.xhtml via
        // AnyURL(legacyHREF:), so the round-tripped href has no leading slash.
        XCTAssertEqual(bookmark.href, "chapter5.xhtml",
                       "Round-tripped href must match what TPPBookLocation's normalizer produced on write")
        XCTAssertEqual(bookmark.device, Self.deviceA,
                       "Bookmark must remain stamped with device A's ID — cross-device read must not relabel")
    }

    // MARK: - Test 4: Bookmark deleted on A, gone on B

    /// Setup: device A posts a bookmark, then deletes it via its annotation
    /// ID. Device B fetches → list must be empty. Exercises the deletion
    /// half of the sync protocol end-to-end.
    func test_bookmarkDeletedOnDeviceA_goneOnDeviceB() async throws {
        try skipIfSyncGateClosed()

        let selectorValue = epubSelectorValue(
            href: "/chapter9.xhtml",
            progressInChapter: 0.50,
            progressInBook: 0.90,
            title: "Chapter 9"
        )

        let local = try XCTUnwrap(TPPReadiumBookmark(
            annotationId: nil,
            href: "/chapter9.xhtml",
            chapter: "Chapter 9",
            page: nil,
            location: selectorValue,
            progressWithinChapter: 0.50,
            progressWithinBook: 0.90,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: ISO8601DateFormatter().string(from: Date()),
            device: Self.deviceA
        ))

        // A creates it. JOIN on the POST completion; serverId is Sendable.
        let serverID: String? =
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                asDeviceA {
                    TPPAnnotations.postBookmark(local, forBookID: Self.bookID) { response in
                        cont.resume(returning: response?.serverId)
                    }
                }
            }
        let assignedID = try XCTUnwrap(serverID, "Setup precondition: POST must return a server ID")
        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 1,
                       "Setup precondition: backend must have one annotation before delete")

        // A deletes it via the same annotation ID the server returned. JOIN on
        // the completion; `success` is a Bool (Sendable), resumed directly.
        let deleteSucceeded: Bool =
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                asDeviceA {
                    TPPAnnotations.deleteBookmark(annotationId: assignedID) { success in
                        cont.resume(returning: success)
                    }
                }
            }
        XCTAssertTrue(deleteSucceeded, "DELETE must report success for existing annotation")

        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 0,
                       "Backend must reflect the deletion immediately")

        // Also record the deletion in the local log — the production code
        // uses this to suppress re-add of a deleted bookmark on next sync.
        TPPBookmarkDeletionLog.shared.logDeletion(annotationId: assignedID,
                                                  forBook: Self.bookID)

        // B reads — list must be empty. JOIN on the completion; project the
        // Sendable facts (nil-ness + count) since [Bookmark] is non-Sendable.
        let book = makeBook()
        let readResult: BookmarkListProjection =
            await withCheckedContinuation { (cont: CheckedContinuation<BookmarkListProjection, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .bookmark
                    ) { bookmarks in
                        cont.resume(returning: BookmarkListProjection(bookmarks))
                    }
                }
            }

        XCTAssertTrue(readResult.wasNonNil, "B's GET must still return a non-nil list (empty page envelope)")
        XCTAssertEqual(readResult.count, 0,
                       "B must not see the deleted bookmark — deletion is propagated through the shared backend")

        // Cleanup: clear the deletion-log entry so we don't poison neighbouring
        // tests' UserDefaults state.
        TPPBookmarkDeletionLog.shared.clearDeletion(annotationId: assignedID,
                                                    forBook: Self.bookID)
    }

    // MARK: - Test 5: Server-wins conflict resolution

    /// Device A and Device B race: B posts its own bookmark, then the server
    /// (out-of-band) overwrites it with a canonical record from another
    /// authoritative source. On B's next sync, the bookmark for that
    /// annotation ID must reflect the server's value, not B's local copy.
    /// This pins the documented "server-wins on conflict" policy.
    func test_annotationConflict_serverWins() async throws {
        try skipIfSyncGateClosed()

        // B writes its own bookmark first.
        let bSelector = epubSelectorValue(
            href: "/chapter1.xhtml",
            progressInChapter: 0.10,
            progressInBook: 0.05,
            title: "Chapter 1 — B's view"
        )
        let localB = try XCTUnwrap(TPPReadiumBookmark(
            annotationId: nil,
            href: "/chapter1.xhtml",
            chapter: "Chapter 1 — B's view",
            page: nil,
            location: bSelector,
            progressWithinChapter: 0.10,
            progressWithinBook: 0.05,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: ISO8601DateFormatter().string(from: Date()),
            device: Self.deviceB
        ))

        // JOIN on the POST completion; serverId is Sendable.
        let assignedID: String? =
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                asDeviceB {
                    TPPAnnotations.postBookmark(localB, forBookID: Self.bookID) { response in
                        cont.resume(returning: response?.serverId)
                    }
                }
            }
        let id = try XCTUnwrap(assignedID, "Server must assign an annotation ID to B's bookmark")

        // Server-side authoritative record arrives (from another device, a
        // batch import, or admin tooling) and overwrites B's annotation
        // under the same ID. The selector text differs so the conflict is
        // observable.
        let serverSelector = epubSelectorValue(
            href: "/chapter12.xhtml",
            progressInChapter: 0.95,
            progressInBook: 0.99,
            title: "Chapter 12 — server canonical"
        )
        let canonical = MockSyncBackend.StoredAnnotation(
            id: id,
            bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.bookmark.rawValue,
            device: Self.deviceA, // a different device contributed the canonical record
            time: "2026-12-31T23:59:59Z",
            selectorValue: serverSelector,
            chapterTitle: "Chapter 12 — server canonical",
            progressWithinBook: 0.99
        )
        backend.replace(id: id, with: canonical)

        // B's next sync must surface the server's canonical record, not its
        // pre-conflict local copy. JOIN on the completion; project the
        // Sendable facts (count + the first element's Readium projection)
        // since [Bookmark] is non-Sendable.
        let book = makeBook()
        let readResult: BookmarkListProjection =
            await withCheckedContinuation { (cont: CheckedContinuation<BookmarkListProjection, Never>) in
                asDeviceB {
                    TPPAnnotations.getServerBookmarks(
                        forBook: book,
                        atURL: Self.baseURL,
                        motivation: .bookmark
                    ) { bookmarks in
                        cont.resume(returning: BookmarkListProjection(bookmarks))
                    }
                }
            }

        XCTAssertEqual(readResult.count, 1, "Exactly one annotation ID exists; server-wins must not duplicate")
        let bookmark = try XCTUnwrap(readResult.first,
                                     "B's first bookmark must be a TPPReadiumBookmark")
        XCTAssertEqual(bookmark.annotationId, id,
                       "Same annotation ID must persist — server-wins replaces value, not key")
        XCTAssertEqual(bookmark.href, "/chapter12.xhtml",
                       "Server-wins: B must observe the server's canonical href, not its own pre-conflict /chapter1.xhtml")
        XCTAssertEqual(bookmark.progressWithinBook, 0.99, accuracy: 0.001,
                       "Server-wins: progress must match the server's record, not B's local 0.05")
        XCTAssertEqual(bookmark.device, Self.deviceA,
                       "Server-wins: device tag must reflect the authoritative writer, not B")
    }

    // MARK: - Test 6: return deletes the listening position, not just bookmarks (3.2.3 Cause 2)

    /// `deleteAllBookmarks(forBook:)` runs on the return path to stop stale
    /// server annotations from resurfacing on re-borrow. Before the 3.2.3 fix
    /// it only deleted `.bookmark`-motivation annotations AND cast the parsed
    /// array to `[TPPReadiumBookmark]` — so an audiobook's `.readingProgress`
    /// listening position (which parses as an `AudioBookmark`) was left on the
    /// server and became authoritative on re-borrow (HelpSpot #18468/#18019/#18449).
    ///
    /// This drives the REAL `TPPAnnotations.deleteAllBookmarks` against the
    /// shared backend and asserts BOTH the `.readingProgress` listening
    /// position AND the `.bookmark` are deleted for the returned book, while an
    /// unrelated OTHER book's bookmark is left untouched (scoping).
    func test_deleteAllBookmarks_deletesUserBookmark_preservesAudiobookPosition_scopedToBook() async throws {
        try skipIfSyncGateClosed()

        let otherBookID = "urn:uuid:cross-device-e2e-OTHER-book"
        let base = Self.baseURL.absoluteString  // ends in "annotations/"

        // Audiobook listening position (motivation=.readingProgress). This is
        // the annotation the pre-3.2.3 code path silently dropped.
        let progressID = base + "progress-1"
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: progressID,
            bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.readingProgress.rawValue,
            device: Self.deviceA,
            time: "2026-01-01T00:00:00Z",
            selectorValue: audiobookSelectorValue(
                readingOrderItem: "track-2.mp3",
                offsetMilliseconds: 42_000,
                chapter: "Chapter 2"
            ),
            chapterTitle: "Chapter 2",
            progressWithinBook: 0.2
        ))

        // A user bookmark for the SAME book (motivation=.bookmark).
        let bookmarkID = base + "bookmark-1"
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: bookmarkID,
            bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.bookmark.rawValue,
            device: Self.deviceA,
            time: "2026-01-01T00:01:00Z",
            selectorValue: audiobookSelectorValue(
                readingOrderItem: "track-3.mp3",
                offsetMilliseconds: 1_000,
                chapter: "Chapter 3"
            ),
            chapterTitle: "Chapter 3",
            progressWithinBook: 0.3
        ))

        // An unrelated OTHER book's bookmark — must NOT be deleted.
        let otherID = base + "other-book-bookmark"
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: otherID,
            bookID: otherBookID,
            motivation: TPPBookmarkSpec.Motivation.bookmark.rawValue,
            device: Self.deviceA,
            time: "2026-01-01T00:02:00Z",
            selectorValue: audiobookSelectorValue(
                readingOrderItem: "track-1.mp3",
                offsetMilliseconds: 0,
                chapter: "Chapter 1"
            ),
            chapterTitle: "Chapter 1",
            progressWithinBook: 0.9
        ))

        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 2,
                       "Setup: the returned book must have both annotations before return")
        XCTAssertEqual(backend.allAnnotations(forBook: otherBookID).count, 1,
                       "Setup: the other book must have its bookmark before return")

        // Drive the real return-cleanup call through device A's executor.
        // Hold the executor override across the async GET→DELETE chain + poll
        // (see holdDeviceAExecutor): the chained DELETEs re-read the override
        // long after this synchronous call returns.
        let book = makeBook(audiobook: true)
        let restoreExecutor = holdDeviceAExecutor()
        defer { restoreExecutor() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TPPAnnotations.deleteAllBookmarks(forBook: book) { continuation.resume() }
        }

        // Deletions are fire-and-forget (GET then chained DELETEs), so the
        // completion above proves nothing. Join the chain itself — this is what
        // makes "the position was PRESERVED" a real assertion instead of one
        // that a starved CI clone could pass simply by nothing having run yet
        // (STARVE-001).
        await TPPAnnotations._awaitDeletionChainForTesting()

        let remaining = backend.allAnnotations(forBook: Self.bookID)

        // THE CONTRACT THAT MATTERS: the patron's place survives the return.
        XCTAssertTrue(remaining.contains { $0.motivation == TPPBookmarkSpec.Motivation.readingProgress.rawValue },
                      "The audiobook LISTENING POSITION must be PRESERVED on return — matching 3.1.0/3.2.0 and the ebook/PDF path. Deleting a patron's place is a product decision that has not been made; see deleteAllBookmarks for the tag-level evidence that it was never a 3.2.0 regression.")

        // PRE-EXISTING GAP (documented, deliberately NOT changed here): an
        // AUDIOBOOK user `.bookmark` is also not deleted. Every annotation
        // Palace writes embeds `"annotationId": ""`, so an `AudioBookmark`
        // parses with no server linkage and `serverAnnotationId` returns nil.
        // 3.1.0/3.2.0 dropped these too (their `as? [TPPReadiumBookmark]` array
        // cast failed wholesale for audiobooks), so this is long-standing
        // behavior — NOT introduced or altered by 3.2.3. Pinned here so the
        // real shipped behavior is visible rather than implied; fixing it means
        // deleting patron data that is currently kept, so it needs the same
        // product decision as the listening position.
        XCTAssertTrue(remaining.contains { $0.motivation == TPPBookmarkSpec.Motivation.bookmark.rawValue },
                      "Pins the PRE-EXISTING audiobook user-bookmark gap (empty embedded annotationId ⇒ no server linkage ⇒ no DELETE). Unchanged since 3.1.0.")

        XCTAssertEqual(backend.allAnnotations(forBook: otherBookID).count, 1,
                       "The unrelated OTHER book's bookmark must be untouched (deletion is scoped to the returned book)")
    }

    // MARK: - Test 6b: EBOOK reading position is PRESERVED on return (Cause 2 scoping)

    /// Cause 2 (delete the stale listening position on return) originally deleted
    /// `.readingProgress` for ALL formats. That over-reached: an EBOOK's
    /// `.readingProgress` is the auto-saved READING PLACE (parses as a
    /// `TPPReadiumBookmark`, not an `AudioBookmark`), and wiping it made a patron
    /// lose their spot across return/re-borrow. The fix scopes the
    /// `.readingProgress` deletion to AUDIOBOOK positions (`AudioBookmark`) only.
    ///
    /// This drives the REAL `deleteAllBookmarks` for an EBOOK and asserts the
    /// `.readingProgress` reading place SURVIVES while the user `.bookmark` is
    /// still deleted. A regression that deletes ebook `.readingProgress` (or that
    /// removes the scoping guard) makes the reading place vanish and fails here.
    func test_deleteAllBookmarks_ebook_preservesReadingProgress_stillDeletesBookmark() async throws {
        try skipIfSyncGateClosed()

        let base = Self.baseURL.absoluteString  // ends in "annotations/"

        // Ebook reading PLACE (motivation=.readingProgress, EPUB locator → parses
        // as TPPReadiumBookmark). This must be PRESERVED across return.
        let progressID = base + "ebook-readingProgress"
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: progressID,
            bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.readingProgress.rawValue,
            device: Self.deviceA,
            time: "2026-01-01T00:00:00Z",
            selectorValue: epubSelectorValue(
                href: "/chapter5.xhtml", progressInChapter: 0.5, progressInBook: 0.3, title: "Chapter 5"
            ),
            chapterTitle: "Chapter 5",
            progressWithinBook: 0.3
        ))

        // A user bookmark for the SAME ebook (motivation=.bookmark) — deleted.
        let bookmarkID = base + "ebook-bookmark"
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: bookmarkID,
            bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.bookmark.rawValue,
            device: Self.deviceA,
            time: "2026-01-01T00:01:00Z",
            selectorValue: epubSelectorValue(
                href: "/chapter6.xhtml", progressInChapter: 0.1, progressInBook: 0.35, title: "Chapter 6"
            ),
            chapterTitle: "Chapter 6",
            progressWithinBook: 0.35
        ))

        XCTAssertEqual(backend.allAnnotations(forBook: Self.bookID).count, 2,
                       "Setup: the ebook must have both annotations before return")

        // EBOOK — not an audiobook.
        let book = makeBook(audiobook: false)
        let restoreExecutor = holdDeviceAExecutor()
        defer { restoreExecutor() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TPPAnnotations.deleteAllBookmarks(forBook: book) { continuation.resume() }
        }
        // `deleteAllBookmarks` completes IMMEDIATELY and deletes in the
        // background, so join the chain itself. This replaces an 8s wall-clock
        // poll that asserted on "whatever happened by the deadline" — under a
        // starved CI clone that read as a pass with the DELETEs still in flight
        // (STARVE-001).
        await TPPAnnotations._awaitDeletionChainForTesting()

        let remaining = backend.allAnnotations(forBook: Self.bookID)
        XCTAssertFalse(remaining.contains { $0.id == bookmarkID },
                       "the user .bookmark must still be deleted on return")
        XCTAssertTrue(remaining.contains { $0.id == progressID },
                      "the EBOOK .readingProgress reading place must be PRESERVED — Cause 2's .readingProgress deletion is scoped to audiobooks (AudioBookmark) only")
        XCTAssertEqual(remaining.map(\.id), [progressID],
                       "exactly the reading position remains: bookmark deleted, ebook reading place kept")
    }

    // MARK: - Test 7: contract snapshot — return cleanup deletes ONLY the user bookmark

    /// Contract snapshot pinning the return-cleanup call shape: for an
    /// audiobook with both a `.bookmark` and a `.readingProgress` server
    /// annotation, `deleteAllBookmarks` must issue a DELETE for the USER
    /// BOOKMARK ONLY. The snapshot is the SORTED set of deleted annotation IDs
    /// (deterministic regardless of the async GET→DELETE interleave).
    ///
    /// This is the guard that makes the "don't delete the patron's place"
    /// decision hard to reverse by accident: any change that re-adds the
    /// `.readingProgress` motivation grows the set and trips the diff loudly,
    /// forcing a deliberate re-record and a product conversation rather than a
    /// silent behavior change. See `deleteAllBookmarks` for why deletion was
    /// removed in build 490.
    func test_deleteAllBookmarks_contract_deletesOnlyUserBookmark() async throws {
        try skipIfSyncGateClosed()

        let base = Self.baseURL.absoluteString
        let bookmarkID = base + "contract-bookmark"
        let progressID = base + "contract-readingProgress"

        backend.seed(MockSyncBackend.StoredAnnotation(
            id: bookmarkID, bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.bookmark.rawValue,
            device: Self.deviceA, time: "2026-01-01T00:00:00Z",
            selectorValue: audiobookSelectorValue(readingOrderItem: "track-1.mp3", offsetMilliseconds: 0, chapter: "Chapter 1"),
            chapterTitle: "Chapter 1", progressWithinBook: 0.1
        ))
        backend.seed(MockSyncBackend.StoredAnnotation(
            id: progressID, bookID: Self.bookID,
            motivation: TPPBookmarkSpec.Motivation.readingProgress.rawValue,
            device: Self.deviceA, time: "2026-01-01T00:01:00Z",
            selectorValue: audiobookSelectorValue(readingOrderItem: "track-2.mp3", offsetMilliseconds: 5_000, chapter: "Chapter 2"),
            chapterTitle: "Chapter 2", progressWithinBook: 0.2
        ))

        // Record DELETE ids via a wrapper handler in front of the backend.
        let log = CallLog()
        let deleted = DeletedIDCollector()
        HTTPStubURLProtocol.reset()
        let backendRef = backend!
        HTTPStubURLProtocol.register { request in
            if request.httpMethod == "DELETE", let id = request.url?.lastPathComponent {
                deleted.add(id)
            }
            return backendRef.handle(request)
        }

        // Hold device A's executor across the fire-and-forget GET→DELETE chain
        // + poll (see holdDeviceAExecutor) so the chained DELETEs route through
        // the mock backend and are recorded, rather than the production
        // executor (NoNetworkURLProtocol -1003) which would record zero DELETEs
        // and snapshot an empty — meaningless — contract.
        let book = makeBook(audiobook: true)
        let restoreExecutor = holdDeviceAExecutor()
        defer { restoreExecutor() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TPPAnnotations.deleteAllBookmarks(forBook: book) { continuation.resume() }
        }
        // Join the fire-and-forget chain so the snapshot below records the FULL
        // set of DELETEs. The old 8s poll made the contract snapshot itself
        // load-dependent: a starved clone would snapshot a partial set of IDs
        // and either drift the baseline or lock in an incomplete contract
        // (STARVE-001).
        await TPPAnnotations._awaitDeletionChainForTesting()

        // Deterministic contract: the SORTED set of deleted annotation IDs.
        for id in deleted.sortedIDs {
            log.record("deleteBookmark", args: ["annotationId": id])
        }
        ContractSnapshot.assert(log, named: "returnCleanup_deletesUserBookmarkOnly")
    }
}

/// Thread-safe collector for DELETE'd annotation IDs (URLSession completions
/// arrive off the main thread).
private final class DeletedIDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func add(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    var sortedIDs: [String] { lock.lock(); defer { lock.unlock() }; return ids.sorted() }
}

// MARK: - Sendable projections
//
// `Bookmark`/`TPPReadiumBookmark`/`AudioBookmark` inherit from NSObject and are
// NOT Sendable, and the annotation completions fire off-main while the
// continuations are `@MainActor`. Rather than smuggle a non-Sendable object
// across that isolation boundary (which trips Swift 6's "sending 'x' risks
// causing data races"), each projection extracts the primitive, Sendable facts
// the assertions check *inside* the completion (on its own isolation) and
// resumes with those. The asserted facts are byte-identical to the originals.

/// The Sendable facts a `TPPReadiumBookmark` assertion needs. `nil` when the
/// bookmark was absent or not a `TPPReadiumBookmark`, mirroring the original
/// `readBack as? TPPReadiumBookmark` unwrap.
private struct ReadiumBookmarkProjection: Sendable {
    let annotationId: String?
    let href: String
    let progressWithinChapter: Float
    let progressWithinBook: Float
    let device: String?

    init?(_ bookmark: Bookmark?) {
        guard let readium = bookmark as? TPPReadiumBookmark else { return nil }
        self.annotationId = readium.annotationId
        self.href = readium.href
        self.progressWithinChapter = readium.progressWithinChapter
        self.progressWithinBook = readium.progressWithinBook
        self.device = readium.device
    }
}

/// The Sendable facts an `AudioBookmark` assertion needs. `nil` when the
/// bookmark was absent or not an `AudioBookmark`, mirroring the original
/// `readBack as? AudioBookmark` unwrap.
private struct AudioBookmarkProjection: Sendable {
    let readingOrderItem: String?
    let readingOrderItemOffsetMilliseconds: Int?

    init?(_ bookmark: Bookmark?) {
        guard let audio = bookmark as? AudioBookmark else { return nil }
        self.readingOrderItem = audio.readingOrderItem
        self.readingOrderItemOffsetMilliseconds = audio.readingOrderItemOffsetMilliseconds
    }
}

/// The Sendable facts a `[Bookmark]?` list assertion needs: whether the list
/// was non-nil, its element count, and the first element projected to a Readium
/// bookmark (nil if absent or not a `TPPReadiumBookmark`). `first` mirrors the
/// original `list.first as? TPPReadiumBookmark` unwrap.
private struct BookmarkListProjection: Sendable {
    let wasNonNil: Bool
    let count: Int
    let first: ReadiumBookmarkProjection?

    init(_ bookmarks: [Bookmark]?) {
        self.wasNonNil = bookmarks != nil
        self.count = bookmarks?.count ?? 0
        self.first = ReadiumBookmarkProjection(bookmarks?.first)
    }
}
