//
//  AudiobookSyncFailureLoggingTests.swift
//  PalaceTests
//
//  `Documents/Logs/palace_error.log` is the log a patron can export, and only
//  `.error` and `.fault` reach it. A refused annotation POST has to land there
//  naming the book and which write failed; a post that cannot say whether it
//  was refused or only queued has to stay out. These tests assert on the
//  persisted line rather than on the call that produced it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceLogging
import PalaceReadingPosition
import PalaceBookModel
import PalaceCatalog
@testable import Palace
@testable import PalaceAudiobookToolkit

// MARK: - Stubs

/// Fails every bookmark POST with the supplied error and holds nothing else.
private final class FailingAnnotationsStub: NSObject, AnnotationsManager, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }

    var syncIsPossibleAndPermitted: Bool { true }

    func postListeningPosition(forBook bookID: String, selectorValue: String, completion: ((AnnotationResponse?) -> Void)?) {
        completion?(nil)
    }

    func postAudiobookBookmark(forBook bookID: String, selectorValue: String) async throws -> AnnotationResponse? {
        throw error
    }

    func getServerBookmarks(forBook book: TPPBook?, atURL annotationURL: URL?, motivation: TPPBookmarkSpec.Motivation, completion: @escaping ([Bookmark]?) -> Void) {
        completion([])
    }

    func deleteBookmark(annotationId: String, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func deleteAllBookmarks(forBook book: TPPBook, completion: @escaping () -> Void) {
        completion()
    }
}

/// Fails every position write with the supplied error.
private final class FailingPositionWriter: PositionWriter, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }

    func save(_ snapshot: PositionSnapshot) async throws -> ServerPositionID? { throw error }
    func load(for bookID: String) async throws -> PositionSnapshot? { nil }
    func cancel(for bookID: String) async {}
}

/// Carries a unique token so each run can find its own line in a log file that
/// other suites also write to.
private struct MarkedSyncError: Error, CustomStringConvertible {
    let token: String
    var description: String { "marked-sync-failure-\(token)" }
}

/// Refuses every POST the way the real stack does: `TPPNetworkResponder` turns
/// each non-2xx into `NSError(domain: "Api call with failure HTTP status")` and
/// returns it alongside the response, so an error-free non-2xx is a shape
/// production never emits (PP-4965 had two tests pass against that shape).
private final class RefusingExecutorStub: TPPNetworkExecutor, @unchecked Sendable {
    var postCallCount = 0
    private let refusedURL: URL
    private let statusCode: Int

    init(url: URL, statusCode: Int) {
        self.refusedURL = url
        self.statusCode = statusCode
        super.init(credentialsProvider: nil, cachingStrategy: .ephemeral)
    }

    override func request(for url: URL, useTokenIfAvailable: Bool = true) -> URLRequest {
        URLRequest(url: url)
    }

    override func POST(_ request: URLRequest,
                       useTokenIfAvailable: Bool,
                       completion: ((Data?, URLResponse?, Error?) -> Void)?) -> URLSessionDataTask? {
        postCallCount += 1
        let response = HTTPURLResponse(url: refusedURL, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
        completion?(nil,
                    response,
                    NSError(domain: "Api call with failure HTTP status",
                            code: TPPErrorCode.responseFail.rawValue,
                            userInfo: nil))
        return nil
    }
}

// MARK: - Tests

@MainActor
final class AudiobookSyncFailureLoggingTests: XCTestCase {

    private var book: TPPBook!
    private var registry: TPPBookRegistryMock!
    private var tracks: Tracks!
    private var syncError: MarkedSyncError!
    /// Held for the whole test: the write paths capture `self` weakly, so a
    /// local-only reference can be released before the write Task runs.
    private var sut: AudiobookBookmarkBusinessLogic!
    /// Puts the library's sync permission back as the test found it.
    private var syncPermissionRestore: (() -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A per-test identifier so the assertion reads only this test's line out
        // of a log file the whole suite appends to.
        book = TPPBookMocker.mockBook(identifier: "sync-log-\(UUID().uuidString)", title: "Sync Log Book")
        registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadSuccessful)
        syncError = MarkedSyncError(token: UUID().uuidString)
        let manifest = try Manifest.from(jsonFileName: ManifestJSON.snowcrash.rawValue, bundle: Bundle(for: type(of: self)))
        tracks = Tracks(manifest: manifest, audiobookID: book.identifier, token: nil)
    }

    override func tearDown() {
        TPPAnnotations.executorOverride = nil
        TPPAnnotations.accountsManagerOverride = nil
        TPPAnnotations.annotationsURLOverride = nil
        TPPAnnotations.offlineQueueOverride = nil
        TPPAnnotations.errorLoggerOverride = nil
        syncPermissionRestore?()
        syncPermissionRestore = nil
        sut = nil
        tracks = nil
        syncError = nil
        registry = nil
        book = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSUT(annotations: AnnotationsManager, positionWriter: PositionWriter? = nil) {
        sut = AudiobookBookmarkBusinessLogic(
            book: book,
            registry: registry,
            annotationsManager: annotations,
            positionWriter: positionWriter
        )
    }

    /// Opens the gates `postReadingPosition` checks before it will POST at all —
    /// a signed-in patron, sync granted on the library, and an annotations URL —
    /// and installs an executor that refuses. Without all of these the method
    /// early-returns having logged nothing, which looks exactly like the
    /// behaviour these tests assert.
    @discardableResult
    private func openPostGate(statusCode: Int = 500) -> RefusingExecutorStub {
        let annotationsURL = URL(string: "https://test.example.com/annotations")!
        let provider = TPPLibraryAccountMock()
        let patron = TPPUserAccountMock()
        patron._credentials = .token(authToken: "tok",
                                     barcode: "12345",
                                     pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        provider.userAccountResolver = { _ in patron }
        if let details = provider.currentAccount?.details {
            let previous = details.syncPermissionGranted
            syncPermissionRestore = { details.syncPermissionGranted = previous }
            details.syncPermissionGranted = true
        }
        let executor = RefusingExecutorStub(url: annotationsURL, statusCode: statusCode)
        TPPAnnotations.executorOverride = executor
        TPPAnnotations.accountsManagerOverride = provider
        TPPAnnotations.annotationsURLOverride = annotationsURL
        // Never let a refusal write a durable row into the app's real
        // simplified.db; a later reachability event would replay it as a POST.
        TPPAnnotations.offlineQueueOverride = OfflineQueueSpy()
        // Without this the reporter's own line also lands in the exportable log
        // in a debug build, and the assertion could read that instead.
        TPPAnnotations.errorLoggerOverride = ErrorLoggerSpy()
        return executor
    }

    // MARK: - Local-store conversion

    /// The early exit in `saveListeningPosition` returns before the registry
    /// write, so a position that cannot be converted to a stored location is
    /// kept neither locally nor on the server. Nothing a `TrackPosition` from a
    /// real manifest produces reaches that exit today, and this pins that: if
    /// conversion ever starts returning nil, the save path stops storing
    /// positions and the new log line is what reports it.
    func testSaveListeningPosition_everyTrackInTheManifest_reachesTheLocalStore() async {
        for index in tracks.tracks.indices {
            registry.setLocation(nil, forIdentifier: book.identifier)
            makeSUT(annotations: FailingAnnotationsStub(error: syncError),
                    positionWriter: FailingPositionWriter(error: syncError))

            sut.saveListeningPosition(at: TrackPosition(track: tracks.tracks[index], timestamp: 7.0, tracks: tracks), completion: nil)
            // Join the write Task rather than leaving one per track running
            // past the end of the iteration.
            await sut._awaitPositionWriteForTesting()

            XCTAssertNotNil(
                registry.location(forIdentifier: book.identifier),
                "Track \(index) (\(tracks.tracks[index].key)) must convert to a stored location; "
                    + "the early exit would drop the position locally and on the server"
            )
        }
    }

    // MARK: - Bookmark

    /// A bookmark post that came back without a server id must NOT reach the
    /// exportable log. `postAudiobookBookmark` throws the same content-free
    /// error for a refusal, for a write queued while offline, and for sync being
    /// off, and this loop runs on every sync pass, so persisting it would fill
    /// the log a patron exports with writes that are pending or configured away
    /// — the PP-4965 volume. The refusal itself is persisted, attributed, by
    /// `postAnnotation`; that is what the tests below cover.
    func testSaveBookmark_whenThePostReturnsNoServerID_staysOutOfTheExportableLog() async {
        let unattributedBook = book.identifier
        makeSUT(annotations: FailingAnnotationsStub(error: syncError))
        let saved = expectation(description: "saveBookmark completion")
        sut.saveBookmark(at: TrackPosition(track: tracks.tracks[1], timestamp: 42.0, tracks: tracks)) { _ in
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 10.0)

        XCTAssertFalse(registry.genericBookmarksForIdentifier(book.identifier).isEmpty,
                       "The bookmark must still be stored locally")

        // A barrier, so the absence below is a real absence and not a read that
        // arrived early: drive a refusal through `postAnnotation`, which does
        // persist, and wait for ITS line. `PersistentLogger` is one actor, so
        // once the later write is visible the earlier one has had its chance.
        let barrierBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()
        let posted = expectation(description: "barrier POST")
        TPPAnnotations.postReadingPosition(forBook: barrierBookID,
                                          selectorValue: "{\"k\":\"v\"}",
                                          motivation: .readingProgress) { _ in posted.fulfill() }
        await fulfillment(of: [posted], timeout: 10.0)
        XCTAssertEqual(executor.postCallCount, 1, "The barrier POST must have gone out")
        await assertRefusalPersisted(naming: barrierBookID,
                                     motivation: .readingProgress,
                                     subject: "The barrier POST")

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        XCTAssertFalse(logs.contains(unattributedBook),
                       "A bookmark post that cannot say whether it was refused or queued must not "
                       + "reach the exportable log; found a line naming \(unattributedBook)")
    }

    /// The position write is the volume driver the bookmark catches are held
    /// below `.error` to avoid: it runs on a 15-second autosave, so one outage
    /// would fill the exported log by itself. Same barrier argument as the
    /// bookmark test above.
    func testSaveListeningPosition_whenTheWriteFails_staysOutOfTheExportableLog() async {
        // Keyed on the error, not the book: the position line interpolates the
        // error but not the identifier, so searching for the book would find
        // nothing whatever the level was and the test could not fail.
        let positionFailureMarker = syncError.description
        makeSUT(annotations: FailingAnnotationsStub(error: syncError),
                positionWriter: FailingPositionWriter(error: syncError))
        sut.saveListeningPosition(at: TrackPosition(track: tracks.tracks[1], timestamp: 42.0, tracks: tracks), completion: nil)
        await sut._awaitPositionWriteForTesting()

        XCTAssertNotNil(registry.location(forIdentifier: book.identifier),
                        "The local position must still be saved")

        let barrierBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()
        let posted = expectation(description: "barrier POST")
        TPPAnnotations.postReadingPosition(forBook: barrierBookID,
                                          selectorValue: "{\"k\":\"v\"}",
                                          motivation: .readingProgress) { _ in posted.fulfill() }
        await fulfillment(of: [posted], timeout: 10.0)
        XCTAssertEqual(executor.postCallCount, 1, "The barrier POST must have gone out")
        await assertRefusalPersisted(naming: barrierBookID,
                                     motivation: .readingProgress,
                                     subject: "The barrier POST")

        let logs = await PersistentLogger.shared.retrieveAllLogs()
        XCTAssertFalse(logs.contains(positionFailureMarker),
                       "A failed position write must not reach the exportable log; "
                       + "found a line carrying \(positionFailureMarker)")
    }

    // MARK: - Attribution on the shared annotation POST

    /// One POST carries reading positions and bookmarks for every format. Its
    /// refusal line already persisted; what it did not say was which book, or
    /// which kind of write, so an exported log reported only that something
    /// failed.
    func testPostReadingPosition_serverRefuses_persistedLineNamesBookAndMotivation() async {
        let attributedBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()

        let posted = expectation(description: "postReadingPosition completion")
        TPPAnnotations.postReadingPosition(forBook: attributedBookID,
                                          selectorValue: "{\"k\":\"v\"}",
                                          motivation: .readingProgress) { _ in posted.fulfill() }
        await fulfillment(of: [posted], timeout: 10.0)

        // Without this the sync gate could have closed and logged nothing,
        // which is indistinguishable from the behaviour being asserted.
        XCTAssertEqual(executor.postCallCount, 1, "The POST must have gone out")

        await assertRefusalPersisted(naming: attributedBookID,
                                     motivation: .readingProgress,
                                     subject: "A refused reading-position POST")
    }

    /// The same POST with the bookmark motivation has to be distinguishable
    /// from the reading-position one in the exported log.
    func testPostAudiobookBookmark_serverRefuses_persistedLineNamesTheBookmarkMotivation() async {
        let attributedBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()

        _ = try? await TPPAnnotations.postAudiobookBookmark(forBook: attributedBookID,
                                                            selectorValue: "{\"k\":\"v\"}")

        XCTAssertEqual(executor.postCallCount, 1, "The POST must have gone out")

        await assertRefusalPersisted(naming: attributedBookID,
                                     motivation: .bookmark,
                                     subject: "A refused bookmark POST")
    }

    /// The EPUB bookmark POST is a separate entry point into the same shared
    /// POST, so its refusal has to be attributed too. The motivation is read off
    /// the serialized payload rather than passed in, which is what makes every
    /// entry point attributed without each one opting in.
    func testPostReadiumBookmark_serverRefuses_persistedLineNamesTheBookmarkMotivation() async {
        let attributedBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()
        guard let bookmark = TPPReadiumBookmark(
            annotationId: "",
            href: "/chapter1.html",
            chapter: "Chapter 1",
            page: nil,
            location: nil,
            progressWithinChapter: 0.5,
            progressWithinBook: 0.25,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0,
            time: "2026-01-01T00:00:00Z",
            device: "test-device"
        ) else {
            XCTFail("Could not build the EPUB bookmark fixture")
            return
        }

        let posted = expectation(description: "postBookmark completion")
        TPPAnnotations.postBookmark(bookmark, forBookID: attributedBookID) { _ in posted.fulfill() }
        await fulfillment(of: [posted], timeout: 10.0)

        XCTAssertEqual(executor.postCallCount, 1, "The POST must have gone out")

        await assertRefusalPersisted(naming: attributedBookID,
                                     motivation: .bookmark,
                                     subject: "A refused EPUB bookmark POST")
    }

    /// Common to every failure line the shared POST persists, so the assertion
    /// reads one of those rather than a neighbour. `TPPNetworkResponder` attaches
    /// an NSError to each non-2xx, so a refusal is reported through the
    /// transport-error line rather than the status-code one.
    ///
    /// The error reporter names the book too, but only in a non-production
    /// build: `DefaultErrorLogger.logError` routes to Crashlytics in production,
    /// which a patron cannot export. That is why attribution has to be on these
    /// lines.
    private static let postFailurePrefix = "Annotation POST"

    private func assertRefusalPersisted(
        naming attributedBookID: String,
        motivation: TPPBookmarkSpec.Motivation,
        subject: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        func refusalLine(_ logs: String) -> String? {
            logs.split(separator: "\n")
                .last { $0.contains(Self.postFailurePrefix) && $0.contains(attributedBookID) }
                .map(String.init)
        }

        await awaitConditionAsync(timeout: 10.0, file: file, line: line) {
            refusalLine(await PersistentLogger.shared.retrieveAllLogs()) != nil
        }
        guard let logLine = refusalLine(await PersistentLogger.shared.retrieveAllLogs()) else {
            XCTFail("\(subject) must persist a line naming the book; nothing opening "
                    + "\"\(Self.postFailurePrefix)\" carried \(attributedBookID)",
                    file: file, line: line)
            return
        }
        XCTAssertTrue(logLine.contains("[ERROR]"),
                      "\(subject) must persist at error level; got: \(logLine)",
                      file: file, line: line)
        // The literal, not `String(describing:)` again: computing the
        // expectation the way the production line does would let a rendering
        // change move both sides together and go unnoticed.
        let expectedMotivation: String
        switch motivation {
        case .bookmark: expectedMotivation = "motivation=bookmark"
        case .readingProgress: expectedMotivation = "motivation=readingProgress"
        }
        XCTAssertTrue(logLine.contains(expectedMotivation),
                      "\(subject) must say which kind of write failed, not just that a POST did; "
                      + "expected \(expectedMotivation), got: \(logLine)",
                      file: file, line: line)
    }

    /// The guard that fires when there is no annotations URL persists its own
    /// `.error`, on a path that never reaches the POST. It named no book either.
    func testPostReadingPosition_whenThereIsNoAnnotationsURL_persistedLineNamesBookAndMotivation() async {
        let attributedBookID = "attribution-\(UUID().uuidString)"
        let executor = openPostGate()
        // `annotationsURLOverride` is a double optional: `.some(nil)` is how a
        // test says "resolved, and there is no URL".
        TPPAnnotations.annotationsURLOverride = .some(nil)

        let posted = expectation(description: "postReadingPosition completion")
        TPPAnnotations.postReadingPosition(forBook: attributedBookID,
                                          selectorValue: "{\"k\":\"v\"}",
                                          motivation: .bookmark) { _ in posted.fulfill() }
        await fulfillment(of: [posted], timeout: 10.0)

        XCTAssertEqual(executor.postCallCount, 0,
                       "The guard must short-circuit before any POST goes out")

        await awaitConditionAsync(timeout: 10.0) {
            await PersistentLogger.shared.retrieveAllLogs().contains(attributedBookID)
        }
        let logs = await PersistentLogger.shared.retrieveAllLogs()
        guard let logLine = logs.split(separator: "\n").last(where: { $0.contains(attributedBookID) }) else {
            XCTFail("The missing-URL guard must persist a line naming the book; "
                    + "nothing carrying \(attributedBookID) was written")
            return
        }
        XCTAssertTrue(logLine.contains("[ERROR]"),
                      "It must persist at error level; got: \(logLine)")
        XCTAssertTrue(logLine.contains("motivation=bookmark"),
                      "It must say which write was abandoned; got: \(logLine)")
    }
}
