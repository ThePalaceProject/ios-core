//
//  RightsManagementDispatcherTests.swift
//  PalaceTests
//
//  Coverage for the per-rights-management dispatch step that
//  RightsManagementDispatcher owns: .unknown / .lcp / .none /
//  .overdriveManifestJSON / .simplifiedBearerTokenJSON happy +
//  failure sub-paths. The Adobe PDF-detection branch is also
//  covered (#if FEATURE_DRM_CONNECTOR) — the non-PDF Adobe path
//  fires a fire-and-forget Task that calls AdobeDRMService and
//  is left untested at this layer.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class RightsManagementDispatcherTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var fileOps: StubFileOps!
    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var spyDelegate: SpyDelegate!
    private var dispatcher: RightsManagementDispatcher!
    private var book: TPPBook!
    private var tempLocation: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        fileOps = StubFileOps()
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        spyDelegate = SpyDelegate()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        tempLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("rmd-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: tempLocation)

        session = URLSession(configuration: .ephemeral)

        // Palace target always builds with FEATURE_DRM_CONNECTOR, so the
        // DRM-on init is the one exported through @testable import Palace.
        // PalaceTests does not redefine the flag, so the source-code #if
        // guard here would resolve incorrectly — call the DRM-on init
        // unconditionally (matches AdobeDRMHandlerTests's pattern).
        dispatcher = RightsManagementDispatcher(
            stateManager: stateManager,
            fileOps: fileOps,
            bookRegistry: bookRegistry,
            userAccountProvider: { [unowned self] in self.userAccount },
            adobeDRMService: AdobeDRMService.shared
        )
        dispatcher.delegate = spyDelegate
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempLocation)
        stateManager = nil
        fileOps = nil
        bookRegistry = nil
        userAccount = nil
        spyDelegate = nil
        dispatcher = nil
        book = nil
        tempLocation = nil
        session = nil
        try super.tearDownWithError()
    }

    private func dispatchTask() -> URLSessionDownloadTask {
        StubDownloadTask(taskIdentifier: 42)
    }

    // MARK: - .unknown

    func testDispatch_unknown_logsAndFlagsFailure() async {
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .unknown, failureError: nil
        )

        XCTAssertTrue(result.failureRequiringAlert,
                      ".unknown must always set failureRequiringAlert")
        XCTAssertEqual(spyDelegate.logCalls.map { $0.reason },
                       ["Unknown rights management"])
    }

    // MARK: - .lcp

    func testDispatch_lcp_callsLcpFulfillmentAndDoesNotFlagFailure() async {
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .lcp, failureError: nil
        )

        XCTAssertFalse(result.failureRequiringAlert,
                       ".lcp delegates fulfillment but doesn't flag failure")
        XCTAssertEqual(spyDelegate.lcpFulfillmentCalls.map { $0.book.identifier }, [book.identifier])
    }

    // MARK: - .overdriveManifestJSON

    func testDispatch_overdrive_replaceBookSuccess_doesNotFlagFailure() async {
        fileOps.replaceBookResult = true
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .overdriveManifestJSON, failureError: nil
        )

        XCTAssertFalse(result.failureRequiringAlert)
        XCTAssertEqual(fileOps.replaceBookCalls, 1)
    }

    func testDispatch_overdrive_replaceBookFails_flagsFailure() async {
        fileOps.replaceBookResult = false
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .overdriveManifestJSON, failureError: nil
        )

        XCTAssertTrue(result.failureRequiringAlert,
                      "replaceBook returning false must propagate as failureRequiringAlert")
    }

    // MARK: - .none

    func testDispatch_none_moveFileSuccess_doesNotFlagFailure() async {
        fileOps.moveFileResult = true
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .none, failureError: nil
        )

        XCTAssertFalse(result.failureRequiringAlert)
        XCTAssertEqual(fileOps.moveFileCalls, 1)
    }

    func testDispatch_none_moveFileFails_flagsFailure() async {
        fileOps.moveFileResult = false
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .none, failureError: nil
        )

        XCTAssertTrue(result.failureRequiringAlert)
    }

    // MARK: - .simplifiedBearerTokenJSON

    func testDispatch_bearerToken_validJSON_registersNewTaskInState() async throws {
        let payload: [String: Any] = [
            "access_token": "secret-token",
            "expires_in": 3600,
            "location": "https://content.example.com/book.epub"
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        try json.write(to: tempLocation)

        let task = dispatchTask()
        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .simplifiedBearerTokenJSON, failureError: nil
        )

        XCTAssertFalse(result.failureRequiringAlert,
                       "Valid bearer-token JSON does not flag failure")

        let cached = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertNotNil(cached, "Bearer-token success must update bookIdentifierToDownloadInfo")
        XCTAssertEqual(cached?.rightsManagement,
                       MyBooksDownloadInfo.MyBooksDownloadRightsManagement.none,
                       "Bearer-token replacement task uses .none rights")

        let registeredBookCount = await stateManager.taskIdentifierToBook.count()
        XCTAssertGreaterThanOrEqual(registeredBookCount, 1,
                                    "Bearer-token success must register the new task identifier")
    }

    func testDispatch_bearerToken_invalidJSON_failsWithAlert() async throws {
        // Garbage bytes — not valid JSON, so simplifiedBearerToken parse fails.
        try Data([0xFF, 0xFE, 0xFD]).write(to: tempLocation)
        let task = dispatchTask()

        _ = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .simplifiedBearerTokenJSON, failureError: nil
        )

        XCTAssertEqual(spyDelegate.failDownloadCalls.map { $0.identifier }, [book.identifier],
                       "Invalid bearer-token JSON must invoke failDownloadWithAlert")
        XCTAssertEqual(spyDelegate.logCalls.first?.reason,
                       "No Simplified Bearer Token in deserialized data")
    }

    func testDispatch_bearerToken_missingFile_failsWithAlert() async {
        // Remove the temp file so Data(contentsOf:) returns nil.
        try? FileManager.default.removeItem(at: tempLocation)
        let task = dispatchTask()

        _ = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .simplifiedBearerTokenJSON, failureError: nil
        )

        XCTAssertEqual(spyDelegate.failDownloadCalls.map { $0.identifier }, [book.identifier])
        XCTAssertEqual(spyDelegate.logCalls.first?.reason,
                       "No Simplified Bearer Token data available on disk")
    }

    // MARK: - .adobe PDF-detection branch

    // Palace target compiles with FEATURE_DRM_CONNECTOR; the dispatcher's
    // .adobe branch only emits behavior when that flag is on. Test runs
    // unconditionally (PalaceTests link against the DRM-on Palace module).
    func testDispatch_adobePDF_returnsFailureWithIgnoreError() async throws {
        // Write an ACSM payload that announces application/pdf format —
        // the dispatcher should reject this as Adobe-PDF-not-supported.
        let acsm = "<?xml version=\"1.0\"?><fulfillmentToken><dc:format>application/pdf</dc:format></fulfillmentToken>"
        try acsm.write(to: tempLocation, atomically: true, encoding: .utf8)
        let task = dispatchTask()

        let result = await dispatcher.dispatch(
            book: book, task: task, location: tempLocation, session: session,
            rights: .adobe, failureError: nil
        )

        XCTAssertTrue(result.failureRequiringAlert,
                      "Adobe-PDF branch must flag failure")
        XCTAssertNotNil(result.failureError, "Adobe-PDF must surface a synthetic ignore error")
        XCTAssertEqual((result.failureError as? NSError)?.code, TPPErrorCode.ignore.rawValue,
                       "Adobe-PDF synthetic error must use TPPErrorCode.ignore so the alert path can suppress it")
        XCTAssertEqual(spyDelegate.logCalls.first?.reason, "Received PDF for AdobeDRM rights")
    }
}

// MARK: - Stubs

private final class StubFileOps: BackgroundDownloadFileOps {
    var replaceBookResult = true
    var moveFileResult = true
    private(set) var replaceBookCalls = 0
    private(set) var moveFileCalls = 0

    func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        replaceBookCalls += 1
        return replaceBookResult
    }

    func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        moveFileCalls += 1
        return moveFileResult
    }
}

private final class SpyDelegate: RightsManagementDispatcherDelegate {
    private(set) var logCalls: [(book: TPPBook, reason: String, metadata: [String: Any]?)] = []
    private(set) var lcpFulfillmentCalls: [(book: TPPBook, location: URL)] = []
    private(set) var failDownloadCalls: [TPPBook] = []
    private(set) var alertCalls: [(book: TPPBook, error: Error?, problemDoc: TPPProblemDocument?)] = []

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        logCalls.append((book, reason, metadata))
    }

    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        lcpFulfillmentCalls.append((book, fileUrl))
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failDownloadCalls.append(book)
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        alertCalls.append((book, error, problemDoc))
    }
}

private final class StubDownloadTask: URLSessionDownloadTask {
    private let _taskIdentifier: Int

    init(taskIdentifier: Int) {
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var taskIdentifier: Int { _taskIdentifier }
    override var originalRequest: URLRequest? {
        URLRequest(url: URL(string: "https://cm.example.com/fulfill")!)
    }
    override func cancel() {}
    override func resume() {}
    override func suspend() {}
}
