//
//  DownloadCompletionParserTests.swift
//  PalaceTests
//
//  Coverage for the pre-dispatch parsing block of the download
//  completion flow that DownloadCompletionParser owns: rights
//  resolution + cache update, problem-document detection, OPDS
//  entry / OPDS2 publication routing, and the canCompleteDownload
//  guard. Each branch returns a distinct DownloadCompletionParseResult
//  case the consumer (MyBooksDownloadCenter) acts on.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class DownloadCompletionParserTests: XCTestCase {

    private var stateManager: DownloadStateManager!
    private var router: StubRouter!
    private var parser: DownloadCompletionParser!
    private var book: TPPBook!
    private var tempLocation: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateManager = DownloadStateManager()
        router = StubRouter()
        parser = DownloadCompletionParser(routing: router, stateManager: stateManager)
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        // Write a small payload to a temp file so the parser's
        // `Data(contentsOf:)` reads succeed and `removeItem` has
        // something to delete.
        tempLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcp-\(UUID().uuidString).bin")
        try Data("payload".utf8).write(to: tempLocation)

        session = URLSession(configuration: .ephemeral)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempLocation)
        stateManager = nil
        router = nil
        parser = nil
        book = nil
        tempLocation = nil
        session = nil
        try super.tearDownWithError()
    }

    // MARK: - Problem document branch

    func testParse_problemDocument_returnsFailureWithParsedDoc() async throws {
        // Write a real RFC 7807 problem doc to the location so
        // TPPProblemDocument.fromProblemResponseData decodes it.
        let body: [String: Any] = [
            "type": "http://example.com/loan-limit",
            "title": "Loan limit reached",
            "status": 403,
            "detail": "You have reached your loan limit.",
            "instance": ""
        ]
        let json = try JSONSerialization.data(withJSONObject: body)
        try json.write(to: tempLocation)
        let task = StubDownloadTask(mimeType: "application/problem+json")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        switch result {
        case .failure(let problemDoc, let mimeType, _):
            XCTAssertEqual(problemDoc?.title, "Loan limit reached")
            XCTAssertEqual(problemDoc?.detail, "You have reached your loan limit.")
            XCTAssertEqual(mimeType, "application/problem+json")
        default:
            XCTFail("Expected .failure, got \(result)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempLocation.path),
                       "Problem-doc branch must remove the downloaded file")
    }

    // MARK: - Rights resolution + cache update

    func testParse_unknownRights_detectsFromMimeAndUpdatesCache() async throws {
        // Seed the cache with an entry whose rights are still .unknown,
        // then drive a completion whose MIME maps to .none. The parser
        // must update the cache to .none.
        let initial = MyBooksDownloadInfo(
            downloadProgress: 0.5,
            downloadTask: StubDownloadTask(mimeType: nil, taskIdentifier: 99),
            rightsManagement: .unknown
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: initial)
        router.detectRightsResult = .none
        let task = StubDownloadTask(mimeType: "application/epub+zip")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .proceed(let rights, let mimeType) = result else {
            return XCTFail("Expected .proceed, got \(result)")
        }
        XCTAssertEqual(rights, .none)
        XCTAssertEqual(mimeType, "application/epub+zip")
        XCTAssertEqual(router.detectRightsCalls, ["application/epub+zip"])

        let cached = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        XCTAssertEqual(cached?.rightsManagement,
                       MyBooksDownloadInfo.MyBooksDownloadRightsManagement.none,
                       "Detected rights must be written back to the cache")
    }

    func testParse_knownRightsInCache_skipsDetection() async throws {
        let initial = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: StubDownloadTask(mimeType: nil, taskIdentifier: 99),
            rightsManagement: .lcp
        )
        await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: initial)
        let task = StubDownloadTask(mimeType: "application/epub+zip")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .proceed(let rights, _) = result else {
            return XCTFail("Expected .proceed, got \(result)")
        }
        XCTAssertEqual(rights, .lcp,
                       "Cached rights take precedence — MIME-based detection must NOT run")
        XCTAssertTrue(router.detectRightsCalls.isEmpty,
                      "detectRightsManagement must not be called when cache is non-unknown")
    }

    // MARK: - OPDS entry routing

    func testParse_OPDSEntry_followUpStarted_returnsFollowUpStarted() async {
        router.opdsEntryResult = true
        let task = StubDownloadTask(mimeType: "application/atom+xml")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        if case .followUpStarted = result {
            // expected
        } else {
            XCTFail("Expected .followUpStarted, got \(result)")
        }
        XCTAssertEqual(router.opdsEntryCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempLocation.path),
                       "Successful OPDS-entry route must remove the temp file")
    }

    func testParse_OPDSEntry_followUpFailed_returnsFailure() async {
        router.opdsEntryResult = false
        let task = StubDownloadTask(mimeType: "text/xml")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .failure(let problemDoc, let mimeType, _) = result else {
            return XCTFail("Expected .failure, got \(result)")
        }
        XCTAssertNil(problemDoc, "OPDS-entry failure path must not synthesize a problem doc")
        XCTAssertEqual(mimeType, "text/xml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempLocation.path))
    }

    // MARK: - OPDS2 publication routing

    func testParse_OPDS2Publication_followUpStarted_returnsFollowUpStarted() async {
        router.opds2PubResult = true
        let task = StubDownloadTask(mimeType: "application/opds-publication+json")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        if case .followUpStarted = result {
            // expected
        } else {
            XCTFail("Expected .followUpStarted, got \(result)")
        }
        XCTAssertEqual(router.opds2PubCalls, 1)
        XCTAssertEqual(router.opdsEntryCalls, 0,
                       "OPDS2-publication path must NOT also invoke the OPDS-entry handler")
    }

    func testParse_OPDS2Publication_followUpFailed_returnsFailure() async {
        router.opds2PubResult = false
        let task = StubDownloadTask(mimeType: "application/opds+json")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .failure = result else {
            return XCTFail("Expected .failure, got \(result)")
        }
    }

    // MARK: - canCompleteDownload guard

    func testParse_unsupportedMime_returnsFailure() async {
        // image/png is not in TPPOPDSAcquisitionPath.supportedTypes()
        let task = StubDownloadTask(mimeType: "image/png")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .failure(let problemDoc, let mimeType, _) = result else {
            return XCTFail("Expected .failure, got \(result)")
        }
        XCTAssertNil(problemDoc)
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempLocation.path),
                       "Unsupported-MIME branch must remove the temp file")
    }

    // MARK: - Happy path

    func testParse_supportedMime_returnsProceed() async {
        let task = StubDownloadTask(mimeType: "application/epub+zip")

        // Swift 6: capture the (now `@unchecked Sendable`) parser as a local so
        // awaiting its nonisolated `async parse` doesn't send `self.parser` off
        // the @MainActor test. Mirrors the DownloadStateManagerTests local-hoist.
        let parser = parser!
        let result = await parser.parse(book: book, task: task, location: tempLocation, session: session)

        guard case .proceed(let rights, let mimeType) = result else {
            return XCTFail("Expected .proceed, got \(result)")
        }
        XCTAssertEqual(mimeType, "application/epub+zip")
        XCTAssertEqual(rights, .none,
                       "Detected rights for application/epub+zip should be .none")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempLocation.path),
                      "Happy path leaves the file in place for the per-rights dispatch step")
    }
}

// MARK: - Stubs

private final class StubRouter: DownloadCompletionRouting {
    var detectRightsResult: MyBooksDownloadInfo.MyBooksDownloadRightsManagement = .none
    var opdsEntryResult: Bool = false
    var opds2PubResult: Bool = false

    private(set) var detectRightsCalls: [String] = []
    private(set) var opdsEntryCalls = 0
    private(set) var opds2PubCalls = 0

    func detectRightsManagement(from mimeType: String) -> MyBooksDownloadInfo.MyBooksDownloadRightsManagement {
        detectRightsCalls.append(mimeType)
        return detectRightsResult
    }

    func isOPDSEntryMimeType(_ mimeType: String) -> Bool {
        let lowered = mimeType.lowercased()
        return lowered == "application/xml" ||
            lowered == "text/xml" ||
            lowered.contains("atom+xml") ||
            lowered.contains("opds-catalog")
    }

    func isOPDS2PublicationMimeType(_ mimeType: String) -> Bool {
        let lowered = mimeType.lowercased()
        return lowered.contains("opds-publication+json") || lowered.contains("opds+json")
    }

    func handleOPDSEntryResponse(at location: URL,
                                 for book: TPPBook,
                                 originalTask: URLSessionDownloadTask,
                                 session: URLSession) async -> Bool {
        opdsEntryCalls += 1
        return opdsEntryResult
    }

    func handleOPDS2PublicationResponse(at location: URL,
                                        for book: TPPBook,
                                        originalTask: URLSessionDownloadTask,
                                        session: URLSession) async -> Bool {
        opds2PubCalls += 1
        return opds2PubResult
    }
}

private final class StubDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let _response: URLResponse?
    private let _taskIdentifier: Int

    init(mimeType: String?, taskIdentifier: Int = 1) {
        if let mimeType = mimeType {
            self._response = URLResponse(
                url: URL(string: "http://example.com/x")!,
                mimeType: mimeType,
                expectedContentLength: -1,
                textEncodingName: nil
            )
        } else {
            self._response = nil
        }
        self._taskIdentifier = taskIdentifier
        super.init()
    }

    override var response: URLResponse? { _response }
    override var taskIdentifier: Int { _taskIdentifier }
    override func cancel() {}
    override func resume() {}
    override func suspend() {}
}
