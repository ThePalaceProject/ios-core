//
//  DownloadReissuePersistenceTests.swift
//  PalaceTests
//
//  PP-5023. Every path that starts a download must durably record it.
//
//  PP-4997 made launch reconciliation match a persisted record against the live
//  tasks by URL, and refuse to adopt when two books claim the same URL. That
//  refusal is computed from persisted records ALONE, so a live task that was
//  never persisted is invisible to it: if book B is downloading on book A's URL
//  without a record, A's record sees exactly one live task on its URL and adopts
//  B's download. The patron gets a title they did not ask for, silently.
//
//  Two paths created a task without recording it — the acquisition-link follow-up
//  in `BackgroundDownloadHandler` and the bearer-token hop in
//  `RightsManagementDispatcher`. These tests pin that they now record, and that
//  recording is what closes the wrong-adoption route.
//
//  The last two tests are a matched pair: one asserts the fix, the other is the
//  CONTROL that proves the assertion can fail. Without the control, a test that
//  declines adoption for some unrelated reason reads exactly like a passing fix.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceBookModel
import PalaceBookRegistry
@testable import Palace

/// Inert session so a task created by the code under test can never reach the
/// network. Sibling suites each carry their own because theirs are fileprivate.
private let inertReissueTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [InertNoOpURLProtocol.self]
    return URLSession(configuration: config)
}()

/// `PalaceWiringTestCase` rather than `XCTestCase`: the sanctioned seam for
/// minting an `AccountsManager`, whose tearDown drains the background work a
/// hand-rolled `AccountsManager()` would leak. Already `@MainActor`.
final class DownloadReissuePersistenceTests: PalaceWiringTestCase {

    /// Per-test persistence file. Without this the suite writes started-task
    /// records into the process-wide default store and leaks fixture records
    /// into sibling suites.
    private lazy var persistenceURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pp5023-\(UUID().uuidString).json")

    private lazy var isolatedStateManager = DownloadStateManager(
        taskPersistence: DownloadTaskPersistence(fileURL: persistenceURL))

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip the synchronous disk-cache preload (root of the FLAKE-003 30s CI
        // timeout). Safe here: nothing in this file reads `accountSets`.
        AccountsManager.deferDiskCachePreloadForTesting = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: persistenceURL)
        AccountsManager.deferDiskCachePreloadForTesting = false
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func record(forBookID bookID: String) -> PersistedDownloadRecord? {
        isolatedStateManager.persistedRecords().first { $0.bookID == bookID }
    }

    /// The URL the handler will actually fetch — read off the fixture rather
    /// than hardcoded, so the assertion cannot drift from the mocker.
    private func acquisitionURL(of book: TPPBook) throws -> URL {
        try XCTUnwrap(book.defaultAcquisition?.hrefURL,
                      "fixture must expose a direct acquisition link")
    }

    // MARK: - The acquisition-link follow-up

    func testFollowAcquisitionLink_persistsTheTaskItStarts() async throws {
        let delegate = MockBackgroundDownloadDelegate(stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let expectedURL = try acquisitionURL(of: book)

        let started = await handler.followAcquisitionLink(
            from: book,
            originalBook: book,
            originalTask: fakeDownloadTask(),
            session: inertReissueTestSession)
        XCTAssertTrue(started, "precondition: the follow-up download must have started")

        let persisted = try XCTUnwrap(
            record(forBookID: book.identifier),
            "the acquisition-link follow-up must durably record the task it started")
        XCTAssertEqual(persisted.downloadURL, expectedURL,
                       "the record must name the URL actually being fetched")

        // The identifier must be the NEW task's, not the dead original's — a
        // record naming a task that no longer exists cannot be adopted.
        let liveInfo = await delegate.stateManager.bookIdentifierToDownloadInfo
            .get(book.identifier)
        let liveTaskID = try XCTUnwrap(liveInfo?.downloadTask.taskIdentifier)
        XCTAssertEqual(persisted.taskIdentifier, liveTaskID,
                       "the record must name the live task, not the one it replaced")
    }

    func testFollowAcquisitionLink_preservesTheAccountTheDownloadStartedUnder() async throws {
        // PP-4978 boundary. `persistStartedTaskRecord` stamps the CURRENT account
        // and upserts by book id, so re-issuing through it would overwrite the
        // started-under account — and `startedForAccount` reads exactly that field
        // to decide which library's credential the next re-issue carries. Writing
        // the current account here would send library B's token to library A.
        let startedLibraryID = "pp5023-started-\(UUID().uuidString)"
        let delegate = MockBackgroundDownloadDelegate(stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 5_023_001,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        _ = await handler.followAcquisitionLink(
            from: book,
            originalBook: book,
            originalTask: fakeDownloadTask(),
            session: inertReissueTestSession)

        let persisted = try XCTUnwrap(record(forBookID: book.identifier))
        XCTAssertEqual(persisted.account, startedLibraryID,
                       "re-issuing must preserve the account the download STARTED under")

        // Without these the test passes vacuously: the seeded record still has
        // the right account simply because nothing rewrote it, which is exactly
        // the pre-fix state. Pinning the record to the NEW task means it can only
        // pass once this path actually writes one.
        let liveInfo = await delegate.stateManager.bookIdentifierToDownloadInfo
            .get(book.identifier)
        let liveTaskID = try XCTUnwrap(liveInfo?.downloadTask.taskIdentifier)
        XCTAssertEqual(persisted.taskIdentifier, liveTaskID,
                       "the preserved-account record must be the re-issued one, not the seeded one")
        XCTAssertEqual(persisted.downloadURL, try acquisitionURL(of: book),
                       "the preserved-account record must name the URL now being fetched")
    }

    func testFollowAcquisitionLink_whenTheBookIdentifierChanges_carriesTheAccountAndDropsTheStaleRecord() async throws {
        // The record is written under the ORIGINAL book at download start, while
        // the follow-up carries an UPDATED book parsed from the server's OPDS
        // entry, whose identifier can differ. Two things must hold: the started-
        // under account has to reach the new record, and the old record must not
        // be left behind naming a task that no longer exists — a stale record is
        // itself an adoption vector on this ticket's own mechanism.
        let startedLibraryID = "pp5023-started-\(UUID().uuidString)"
        let delegate = MockBackgroundDownloadDelegate(stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let originalBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let updatedBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        XCTAssertNotEqual(originalBook.identifier, updatedBook.identifier,
                          "precondition: the fixture books must have distinct identifiers")

        isolatedStateManager.persistStartedTask(
            bookID: originalBook.identifier,
            taskIdentifier: 5_023_002,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/book")!,
            account: startedLibraryID,
            expectedBytes: nil)

        _ = await handler.followAcquisitionLink(
            from: updatedBook,
            originalBook: originalBook,
            originalTask: fakeDownloadTask(),
            session: inertReissueTestSession)

        let carried = try XCTUnwrap(
            record(forBookID: updatedBook.identifier),
            "the updated book must carry a record for the task now running")
        XCTAssertEqual(carried.account, startedLibraryID,
                       "the started-under account must survive an identifier change")
        XCTAssertNil(record(forBookID: originalBook.identifier),
                     "the superseded record must not be left naming a dead task")
    }

    func testFollowAcquisitionLink_withNoPriorRecord_recordsAnEmptyAccount() async throws {
        // The floor. With nothing to preserve, the account must be empty rather
        // than the current one: `startedForAccount` degrades an empty id to
        // today's account, so empty reproduces today's behaviour exactly, while a
        // current-account stamp would be a new and wrong assertion about history.
        let delegate = MockBackgroundDownloadDelegate(stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // Deliberately no persistStartedTask call.

        _ = await handler.followAcquisitionLink(
            from: book,
            originalBook: book,
            originalTask: fakeDownloadTask(),
            session: inertReissueTestSession)

        let persisted = try XCTUnwrap(record(forBookID: book.identifier))
        XCTAssertEqual(persisted.account, "",
                       "with no prior record the account must be empty, not the current library")
    }

    // MARK: - The inheritance cells

    func testReissue_whenTheSourceHasNoRecordButTheTargetDoes_keepsTheTargetsAccount() throws {
        // The cell a mutation run named: `inheritingFrom` points at a book with
        // NO record, while the target book already has one. Reading only the
        // source yields nil and blanks an account that was already correct —
        // which `startedForAccount` would then degrade to the CURRENT library,
        // sending the wrong credential. The target's own record is the fallback.
        let targetLibraryID = "pp5023-target-\(UUID().uuidString)"
        let targetBookID = "pp5023-target-book-\(UUID().uuidString)"

        isolatedStateManager.persistStartedTask(
            bookID: targetBookID,
            taskIdentifier: 5_023_010,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/target")!,
            account: targetLibraryID,
            expectedBytes: nil)

        isolatedStateManager.persistReissuedTask(
            bookID: targetBookID,
            taskIdentifier: 5_023_011,
            downloadURL: URL(string: "https://content.palace-test.invalid/reissued")!,
            inheritingFrom: "pp5023-source-with-no-record-\(UUID().uuidString)")

        let persisted = try XCTUnwrap(record(forBookID: targetBookID))
        XCTAssertEqual(persisted.account, targetLibraryID,
                       "an absent source must fall back to the target's own record, not blank the account")
        XCTAssertEqual(persisted.taskIdentifier, 5_023_011,
                       "and it must still be the re-issued record")
    }

    func testReissue_whenNeitherSourceNorTargetHasARecord_writesAnEmptyAccount() throws {
        // The floor for the arm above. Empty is correct here — there is nothing
        // to inherit — and `startedForAccount` degrades an empty id to today's
        // account, which is the pre-existing behaviour.
        let bookID = "pp5023-orphan-\(UUID().uuidString)"

        isolatedStateManager.persistReissuedTask(
            bookID: bookID,
            taskIdentifier: 5_023_012,
            downloadURL: URL(string: "https://content.palace-test.invalid/orphan")!,
            inheritingFrom: "pp5023-also-absent-\(UUID().uuidString)")

        let persisted = try XCTUnwrap(record(forBookID: bookID))
        XCTAssertEqual(persisted.account, "",
                       "with nothing to inherit the account must be empty, not invented")
    }

    // MARK: - The bearer-token hop

    func testBearerTokenHop_persistsTheTaskItStarts() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bearerLocation = URL(string: "https://content.palace-test.invalid/pp5023-bearer.epub")!

        let location = try Self.writeBearerPayload(location: bearerLocation)
        defer { try? FileManager.default.removeItem(at: location) }

        let dispatcher = makeDispatcher()

        _ = await dispatcher.dispatch(
            book: book,
            task: fakeDownloadTask(),
            location: location,
            session: inertReissueTestSession,
            rights: .simplifiedBearerTokenJSON,
            failureError: nil)

        let persisted = try XCTUnwrap(
            record(forBookID: book.identifier),
            "the bearer-token hop must durably record the task it started")
        XCTAssertEqual(persisted.downloadURL, bearerLocation,
                       "the record must name the bearer location actually being fetched")

        // Both the completed fulfilment task and the new content task are in
        // scope at the production call site, so a record naming the WRONG one
        // survives an existence-and-URL assertion. It must name the live task —
        // a record pointing at a task that no longer exists cannot be adopted.
        // `palace_mutate` finds no mutation points in that file, so this
        // assertion is the only guard on the field.
        let liveInfo = await isolatedStateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        let liveTaskID = try XCTUnwrap(liveInfo?.downloadTask.taskIdentifier)
        XCTAssertEqual(persisted.taskIdentifier, liveTaskID,
                       "the record must name the new bearer task, not the fulfilment task it replaced")
    }

    func testBearerTokenHop_preservesTheAccountTheDownloadStartedUnder() async throws {
        // The production-realistic shape, which the test above deliberately is
        // not: in production this hop always runs for a book whose download was
        // already recorded at start. The call site omits `inheritingFrom`, so the
        // carry rides on the `sourceBookID ?? bookID` default — and
        // `challengeAccount` reads this account on a 401 during the content
        // transfer, so it decides which library's credential is re-sent.
        let startedLibraryID = "pp5023-bearer-started-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bearerLocation = URL(string: "https://content.palace-test.invalid/pp5023-bearer-acct.epub")!

        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: 5_023_003,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/fulfill")!,
            account: startedLibraryID,
            expectedBytes: nil)

        let location = try Self.writeBearerPayload(location: bearerLocation)
        defer { try? FileManager.default.removeItem(at: location) }

        _ = await makeDispatcher().dispatch(
            book: book,
            task: fakeDownloadTask(),
            location: location,
            session: inertReissueTestSession,
            rights: .simplifiedBearerTokenJSON,
            failureError: nil)

        let persisted = try XCTUnwrap(record(forBookID: book.identifier))
        XCTAssertEqual(persisted.account, startedLibraryID,
                       "the bearer hop must preserve the account the download STARTED under")
        XCTAssertEqual(persisted.downloadURL, bearerLocation,
                       "and must be the re-issued record, not the seeded one")
    }

    /// A download task that reports a Content-Type, which the completion parser
    /// requires before it will hand off to the rights dispatcher.
    private static func taskWithContentType(
        _ contentType: String, identifier: Int
    ) -> URLSessionDownloadTask {
        MockURLSessionDownloadTask(
            taskIdentifier: identifier,
            request: URLRequest(url: URL(string: "https://library-a.palace-test.invalid/fulfill")!),
            response: HTTPURLResponse(
                url: URL(string: "https://library-a.palace-test.invalid/fulfill")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]))
    }

    /// Writes a bearer-token JSON payload to a temp file, as the fulfilment
    /// response would.
    private static func writeBearerPayload(location bearerLocation: URL) throws -> URL {
        let payload: [String: Any] = [
            "access_token": "pp5023-token",
            "expires_in": 3600,
            "location": bearerLocation.absoluteString
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5023-bearer-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    /// The bearer hop must report that it left a live task behind, so the
    /// caller's terminal cleanup does not drop the record it just wrote.
    ///
    /// This is the shape that made the bearer half of PP-5023 inert. The hop
    /// writes the record inside `dispatch`; `handleDownloadCompletion` then runs
    /// `removePersistedRecord(for: book.identifier)` about 100ms later on the
    /// same key, so the bearer content transfer ran for minutes with no record —
    /// exactly the pre-fix state. A test that drives `dispatch` alone cannot see
    /// that, because the caller is what undoes the write.
    func testBearerTokenHop_reportsALiveFollowUpTask_soTheCallerKeepsTheRecord() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let bearerLocation = URL(string: "https://content.palace-test.invalid/pp5023-followup.epub")!
        let location = try Self.writeBearerPayload(location: bearerLocation)
        defer { try? FileManager.default.removeItem(at: location) }

        let result = await makeDispatcher().dispatch(
            book: book,
            task: fakeDownloadTask(),
            location: location,
            session: inertReissueTestSession,
            rights: .simplifiedBearerTokenJSON,
            failureError: nil)

        XCTAssertTrue(result.followUpTaskInFlight,
                      "a resumed bearer task is still downloading; the caller must not treat it as terminal")
    }

    /// The control for the arm above: a dispatch that leaves NO task running must
    /// report so, or the caller would stop retiring records at all and every
    /// completed download would leak one forever.
    func testNonFollowUpDispatch_reportsNoLiveTask() async throws {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5023-notbearer-\(UUID().uuidString).json")
        try Data("not a bearer token".utf8).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }

        let result = await makeDispatcher().dispatch(
            book: book,
            task: fakeDownloadTask(),
            location: location,
            session: inertReissueTestSession,
            rights: .simplifiedBearerTokenJSON,
            failureError: nil)

        XCTAssertFalse(result.followUpTaskInFlight,
                       "no task was started, so the caller must run its normal terminal cleanup")
    }

    /// `AdobeDRMService` has no protocol and the dispatcher takes it concretely,
    /// so the singleton goes in here. It is inert for this test: the
    /// `.simplifiedBearerTokenJSON` arm never touches it. Documented rather than
    /// worked around — the inability to inject it is production-code feedback.
    ///
    /// No `#if FEATURE_DRM_CONNECTOR` around this: that flag is set on the app
    /// target and NOT on `PalaceTests`, so from here the DRM initializer is the
    /// only one that exists. Guarding it would compile the wrong arm and fail.
    private func makeDispatcher() -> RightsManagementDispatcher {
        RightsManagementDispatcher(
            stateManager: isolatedStateManager,
            fileOps: BackgroundDownloadHandler(),
            bookRegistry: TPPBookRegistryMock(),
            userAccountProvider: { TPPUserAccountMock() },
            adobeDRMService: AdobeDRMService.shared)
    }

    // MARK: - The caller must HONOUR the follow-up signal

    /// Drives `MyBooksDownloadCenter.handleDownloadCompletion` — the caller —
    /// rather than `dispatch`, and asserts the bearer record SURVIVES.
    ///
    /// This is the test round 1 was missing, and its absence was the defect:
    /// the hop wrote a record inside `dispatch`, and ~100ms later the caller's
    /// terminal cleanup ran `removePersistedRecord` on the same key. Every test
    /// that drove `dispatch` alone stayed green while the fix did nothing.
    ///
    /// Two reviewers independently observed that the guard added to fix it
    /// (`if !followUpTaskInFlight`) was itself unpinned — no test reached the
    /// caller, and `palace_mutate` finds no mutation point on that line — so
    /// deleting it would have restored the defect silently. That is the same
    /// mistake one level up, which is exactly why this test drives the caller.
    func testHandleDownloadCompletion_bearerHop_keepsTheRecordForTheLiveTask() async throws {
        let registry = TPPBookRegistryMock()
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            stateManager: isolatedStateManager,
            reachability: MockReachability(initiallyConnected: true))

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        // A response-bearing task: `DownloadCompletionParser` rejects the download
        // outright via `canCompleteDownload(withContentType:)` when the MIME type
        // is empty, and never reaches the dispatcher. A bare `fakeDownloadTask()`
        // therefore exercises the failure path and cannot see this guard at all —
        // which is how the first version of this test passed for the wrong reason.
        let fulfilmentTask = Self.taskWithContentType(
            DistributorType.EpubZip.rawValue, identifier: 5_023_500)
        let bearerLocation = URL(string: "https://content.palace-test.invalid/pp5023-caller.epub")!

        // Rights are read from the state manager, so the bearer arm is reachable
        // without synthesising an HTTP response.
        await isolatedStateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(
                downloadProgress: 0.0,
                downloadTask: fulfilmentTask,
                rightsManagement: .simplifiedBearerTokenJSON))
        await isolatedStateManager.taskIdentifierToBook.set(
            fulfilmentTask.taskIdentifier, value: book)

        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: fulfilmentTask.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/fulfill")!,
            account: "pp5023-caller-account",
            expectedBytes: nil)

        let location = try Self.writeBearerPayload(location: bearerLocation)
        defer { try? FileManager.default.removeItem(at: location) }

        await center.handleDownloadCompletion(
            session: inertReissueTestSession, task: fulfilmentTask, location: location)

        let persisted = try XCTUnwrap(
            record(forBookID: book.identifier),
            "the terminal cleanup must NOT retire a record whose download has just started")
        XCTAssertEqual(persisted.downloadURL, bearerLocation,
                       "and the surviving record must be the re-issued one")
    }

    /// The control. A completion with NO follow-up task must still retire its
    /// record, or every finished download leaks one forever and launch
    /// reconciliation accumulates records for books that are long since done.
    func testHandleDownloadCompletion_withoutAFollowUp_stillRetiresTheRecord() async throws {
        let registry = TPPBookRegistryMock()
        let center = MyBooksDownloadCenter(
            bookRegistry: registry,
            stateManager: isolatedStateManager,
            reachability: MockReachability(initiallyConnected: true))

        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let task = Self.taskWithContentType(
            DistributorType.EpubZip.rawValue, identifier: 5_023_501)

        // `.none` — a plain content download that completes. No hop, no live task.
        await isolatedStateManager.bookIdentifierToDownloadInfo.set(
            book.identifier,
            value: MyBooksDownloadInfo(
                downloadProgress: 1.0, downloadTask: task, rightsManagement: .none))
        await isolatedStateManager.taskIdentifierToBook.set(task.taskIdentifier, value: book)

        isolatedStateManager.persistStartedTask(
            bookID: book.identifier,
            taskIdentifier: task.taskIdentifier,
            downloadURL: URL(string: "https://library-a.palace-test.invalid/plain")!,
            account: "",
            expectedBytes: nil)

        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp5023-plain-\(UUID().uuidString).epub")
        try Data("not really an epub".utf8).write(to: location)
        defer { try? FileManager.default.removeItem(at: location) }

        await center.handleDownloadCompletion(
            session: inertReissueTestSession, task: task, location: location)

        XCTAssertNil(
            record(forBookID: book.identifier),
            "a download with no follow-up reached a terminal outcome; its record must be dropped")
    }

    // MARK: - What the recording actually buys: no wrong adoption

    func testAcquisitionLinkTask_isNotAdoptedByAnotherBookSharingItsURL() async throws {
        // The ticket's stated acceptance. Book A was killed mid-download and its
        // record names URL X. Book B is now live on URL X via the acquisition-link
        // follow-up. A must NOT adopt B's download.
        let delegate = MockBackgroundDownloadDelegate(stateManager: isolatedStateManager)
        let handler = BackgroundDownloadHandler()
        handler.delegate = delegate

        let bookB = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let sharedURL = try acquisitionURL(of: bookB)

        let bookAID = "pp5023-book-a-\(UUID().uuidString)"
        isolatedStateManager.persistStartedTask(
            bookID: bookAID,
            taskIdentifier: 5_023_100,
            downloadURL: sharedURL,
            account: "",
            expectedBytes: nil)

        _ = await handler.followAcquisitionLink(
            from: bookB,
            originalBook: bookB,
            originalTask: fakeDownloadTask(),
            session: inertReissueTestSession)

        let liveInfo = await delegate.stateManager.bookIdentifierToDownloadInfo
            .get(bookB.identifier)
        let liveTaskID = try XCTUnwrap(liveInfo?.downloadTask.taskIdentifier)

        let decisions = DownloadReconciliation.reconcile(
            persisted: isolatedStateManager.persistedRecords(),
            liveTasks: [liveTaskID: sharedURL],
            registryStates: [bookAID: .downloading, bookB.identifier: .downloading])

        XCTAssertFalse(
            decisions.contains(.adopt(bookID: bookAID, taskIdentifier: liveTaskID)),
            "book A must not adopt book B's acquisition-link download")
        XCTAssertFalse(
            decisions.contains { if case .adopt(let id, _) = $0 { return id == bookAID }; return false },
            "book A must not adopt ANY task on a URL another book is also downloading")

        // Pin the patron-visible consequence, not just the absence of theft. The
        // fix converts "A silently receives B's file" into `.restart` for BOTH —
        // and for the live book B that means orphaned callbacks and an eventual
        // heal to `.downloadFailed`. That is the accepted cost of declining an
        // ambiguous adoption, and it should fail loudly if it ever changes.
        XCTAssertEqual(
            Set(decisions.map(String.init(describing:))),
            Set([ReconcileDecision.restart(bookID: bookAID),
                 ReconcileDecision.restart(bookID: bookB.identifier)].map(String.init(describing:))),
            "both claimants of a contested URL restart; neither adopts")
    }

    func testControl_anUnrecordedTaskOnAnotherBooksURL_isAdopted() throws {
        // CONTROL for the test above, and the defect itself stated as a test.
        // Same inputs, except book B's task was never persisted — which is
        // precisely what the two unrecorded paths used to produce. The guard is
        // computed from persisted records alone, so it cannot see B, and A adopts
        // B's download.
        //
        // If this ever starts failing, the test above stops being evidence: it
        // would be declining adoption for some reason other than the record.
        let sharedURL = URL(string: "https://content.palace-test.invalid/pp5023-shared.epub")!
        let bookAID = "pp5023-book-a-\(UUID().uuidString)"
        let liveTaskID = 5_023_200

        let decisions = DownloadReconciliation.reconcile(
            persisted: [PersistedDownloadRecord(
                bookID: bookAID,
                taskIdentifier: 5_023_201,
                downloadURL: sharedURL,
                account: "",
                expectedBytes: nil,
                startedAt: Date())],
            liveTasks: [liveTaskID: sharedURL],
            registryStates: [bookAID: .downloading])

        XCTAssertEqual(
            decisions, [.adopt(bookID: bookAID, taskIdentifier: liveTaskID)],
            "control: with no record for the live task's owner, the guard is blind and A adopts it")
    }
}
