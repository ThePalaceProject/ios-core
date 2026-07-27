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
        let dict: [String: Any] = [
            "@type": "LocatorAudioBookTime",
            "@version": 2,
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
