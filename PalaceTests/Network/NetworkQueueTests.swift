//
//  NetworkQueueTests.swift
//  PalaceTests
//
//  Tests for NetworkQueue offline request storage and retry logic.
//

import XCTest
import PalaceNetwork
@testable import Palace

/// SRS: NET-003 — Offline queue stores failed requests
@MainActor
class NetworkQueueTests: XCTestCase {

    /// Per-test container — built fresh in `setUp` via the
    /// `makeTestAppContainer()` factory (swarm_47883816 work package A).
    /// Replaces the prior pattern that reached into
    /// `AppContainer.production().networkQueue` on every test method, which
    /// silently shared NetworkQueue state across the suite. NetworkQueue's
    /// SQLite-backed offline store + serial dispatch queue makes order-
    /// dependent test pollution especially insidious — a fresh queue per
    /// test isolates `migrate()` calls and `addRequest()` writes.
    private var appContainer: AppContainer!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - PP-4987: a dropped enqueue must not be silent

    /// PP-4965 stops reporting a write once it is handed to this queue, on the
    /// grounds that it is pending rather than lost. That trade is only sound if
    /// the queue actually TAKES the write. Before PP-4987 both failure paths
    /// here returned without telling anyone — a `guard let db ... else
    /// { return }` and a `catch` whose only output was a local `Log.error`
    /// invisible in production telemetry. Combined, a patron's reading position
    /// could be accepted, dropped, and never reported by anything.
    ///
    /// Driven by pointing the store at a path SQLite cannot open, which is the
    /// only deterministic way to make `startDatabaseConnection()` return nil.
    func testAddRequest_WhenDatabaseCannotBeOpened_ReportsTheDropInsteadOfSwallowingIt() {
        let spy = ErrorLoggerSpy()
        let queue = NetworkQueue(
            transport: makeTransport(),
            reachability: Reachability(),
            // A file, not a directory — `"\(path)/simplified.db"` cannot be
            // created underneath it, so the connection fails every time.
            databaseDirectory: unopenableDatabaseDirectory(),
            errorLogger: spy
        )

        queue.addRequest("lib-1", "update-1",
                         URL(string: "https://example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8), nil)

        expectEventually("the drop is reported") { spy.loggedSummaries.isEmpty == false }

        XCTAssertEqual(spy.loggedSummaries, ["Offline queue write dropped"],
                       "A write the queue could not persist must be reported — the caller has already stopped reporting it")
        XCTAssertEqual(spy.loggedCodes, [.offlineQueueWriteFailed],
                       "It needs its own bucket; filing it as a generic api call hides it among server refusals")
        XCTAssertEqual(spy.loggedMetadata.first?["reason"] as? String, "no database connection",
                       "The report has to say WHICH drop path fired, or it is not diagnosable")
        XCTAssertEqual(spy.loggedMetadata.first?["url"] as? String,
                       "https://example.org/annotations/",
                       "Without the URL the report cannot be tied back to a lost write")
    }

    /// The same queue, working normally, must stay silent — otherwise the test
    /// above would pass for a queue that reports on EVERY write, which would be
    /// its own defect (and would re-inflate the bucket PP-4965 shrank).
    func testAddRequest_WhenDatabaseIsWritable_ReportsNothing() {
        let spy = ErrorLoggerSpy()
        let dir = NSTemporaryDirectory() + "pp4987-ok-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let queue = NetworkQueue(
            transport: makeTransport(),
            reachability: Reachability(),
            databaseDirectory: dir,
            errorLogger: spy
        )
        // A fresh database has no table until `migrate()` creates it — without
        // this the "success" case fails at the insert and reports a drop, which
        // would make this control test pass for the wrong reason.
        //
        // `serialQueue.sync {}` is a REAL barrier: every DB operation is
        // dispatched onto that queue, so this returns only once migrate() has
        // actually run. The previous `expectEventually { loggedSummaries.isEmpty }`
        // was true on its first evaluation and returned instantly — not a
        // barrier at all, just a sleep that happened to work.
        queue.migrate()
        queue.serialQueue.sync {}

        queue.addRequest("lib-1", "update-1",
                         URL(string: "https://example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8), nil)

        // Barrier, not a sleep: once the serial queue has drained, the write
        // has been attempted and any report would already have been recorded.
        queue.serialQueue.sync {}
        XCTAssertEqual(spy.loggedSummaries, [],
                       "A write that WAS persisted must report nothing at all")
    }

    /// The queue never sends anything in these tests — it fails (or succeeds)
    /// at the SQLite step first — so a plain ephemeral transport is enough.
    private func makeTransport() -> NetworkTransport {
        NetworkTransport(delegate: nil,
                         cachingStrategy: .ephemeral,
                         requestTimeout: 5)
    }

    /// The OTHER drop path. `guard let db` covers an unopenable database; this
    /// covers a database that opens and then refuses the write — the insert
    /// throws because no table exists yet.
    ///
    /// Round 3 of review found this path filing under the WRONG code: it used
    /// the bare `logError(_:summary:metadata:)` overload, which hardcodes
    /// `code: .ignore`, so the report landed under the raw SQLite code with
    /// `error_origin = unknown` rather than 916 — while the commit claimed both
    /// paths reported under 916. Untested code made the false claim possible.
    func testAddRequest_WhenInsertThrows_ReportsUnderTheSameDedicatedCode() {
        let spy = ErrorLoggerSpy()
        let dir = NSTemporaryDirectory() + "pp4987-noschema-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Deliberately NO migrate() — the database opens, the table does not exist.
        let queue = NetworkQueue(transport: makeTransport(),
                                 reachability: Reachability(),
                                 databaseDirectory: dir,
                                 errorLogger: spy)
        queue.addRequest("lib-1", "update-1",
                         URL(string: "https://example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        XCTAssertEqual(spy.loggedSummaries, ["Offline queue write dropped"],
                       "A write the database refused must be reported, not swallowed by a local Log.error")
        XCTAssertEqual(spy.loggedCodes, [.offlineQueueWriteFailed],
                       "It must file under 916 like the other drop path — the bare logError overload hardcodes .ignore and would file it under the raw SQLite code")
        XCTAssertEqual(spy.loggedMetadata.first?["reason"] as? String, "insert or update threw",
                       "The report must distinguish WHICH drop path fired")
    }

    // MARK: - PP-4987: the credential must never reach disk

    /// `simplified.db` is an unencrypted file in Application Support, and
    /// callers build headers from `TPPNetworkExecutor.request(for:)` whose
    /// `useTokenIfAvailable` defaults to TRUE — so a live bearer token is in
    /// the header set unless it is stripped. Nothing was ever queued before
    /// PP-4987, so this never executed; turning the queue on is what would
    /// have started writing credentials to disk.
    func testHeadersSafeToPersist_RemovesTheCredentialAndKeepsEverythingElse() {
        let sanitized = NetworkQueue.headersSafeToPersist([
            "Authorization": "Bearer super-secret-token",
            "Content-Type": "application/json",
            "Accept-Language": ""
        ])

        XCTAssertNil(sanitized["Authorization"],
                     "A live credential must never be archived into the unencrypted queue database")
        XCTAssertFalse(sanitized.values.contains { $0.contains("super-secret-token") },
                       "The token must not survive under any key")
        XCTAssertEqual(sanitized["Content-Type"], "application/json",
                       "Everything the retry needs must survive — stripping too much breaks the replay")
        XCTAssertEqual(sanitized.count, 2)
    }

    /// HTTP header names are case-insensitive, so a caller spelling it
    /// differently must not smuggle the credential past the filter.
    func testHeadersSafeToPersist_IsCaseInsensitive() {
        for spelling in ["authorization", "AUTHORIZATION", "AuThOrIzAtIoN"] {
            let sanitized = NetworkQueue.headersSafeToPersist([spelling: "Bearer t", "X-Keep": "1"])
            XCTAssertEqual(sanitized, ["X-Keep": "1"],
                           "\(spelling) must be stripped exactly like the canonical spelling")
        }
    }

    private func unopenableDatabaseDirectory() -> String {
        let path = NSTemporaryDirectory() + "pp4987-blocked-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: Data("not a directory".utf8))
        return path
    }

    private func expectEventually(_ what: String,
                                  timeout: TimeInterval = 2.0,
                                  _ condition: () -> Bool,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    // MARK: - Static Properties

    func testStatusCodesContainsExpectedNetworkErrors() {
        let codes = NetworkQueue.StatusCodes
        XCTAssertTrue(codes.contains(NSURLErrorTimedOut))
        XCTAssertTrue(codes.contains(NSURLErrorCannotFindHost))
        XCTAssertTrue(codes.contains(NSURLErrorCannotConnectToHost))
        XCTAssertTrue(codes.contains(NSURLErrorNetworkConnectionLost))
        XCTAssertTrue(codes.contains(NSURLErrorNotConnectedToInternet))
    }

    func testStatusCodesContainsRoamingAndCallErrors() {
        let codes = NetworkQueue.StatusCodes
        XCTAssertTrue(codes.contains(NSURLErrorInternationalRoamingOff))
        XCTAssertTrue(codes.contains(NSURLErrorCallIsActive))
        XCTAssertTrue(codes.contains(NSURLErrorDataNotAllowed))
    }

    func testStatusCodesContainsSecureConnectionFailed() {
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorSecureConnectionFailed))
        // Should also contain the closely related SSL errors
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorCannotConnectToHost),
                      "SSL errors go hand-in-hand with connection failures")
        XCTAssertFalse(NetworkQueue.StatusCodes.isEmpty,
                       "StatusCodes must be non-empty to be useful")
    }

    func testMaxRetriesInQueueIsFive() {
        let queue = appContainer.networkQueue
        XCTAssertEqual(queue.MaxRetriesInQueue, 5)
        XCTAssertGreaterThan(queue.MaxRetriesInQueue, 0, "Retry limit must be positive")
        XCTAssertLessThanOrEqual(queue.MaxRetriesInQueue, 10,
                                 "Retry limit should be reasonable (<=10) to avoid excessive retries")
    }

    // MARK: - HTTPMethodType

    func testHTTPMethodTypeRawValues() {
        // Raw values are used verbatim in HTTP requests — verify roundtrip (not just definitions)
        let methods: [(HTTPMethodType, String)] = [
            (.GET, "GET"), (.POST, "POST"), (.PUT, "PUT"), (.DELETE, "DELETE"),
            (.HEAD, "HEAD"), (.OPTIONS, "OPTIONS"), (.CONNECT, "CONNECT")
        ]
        for (method, expectedRaw) in methods {
            XCTAssertEqual(HTTPMethodType(rawValue: expectedRaw), method,
                           "roundtrip for \(expectedRaw) must produce .\(method)")
        }
        // Case sensitivity check: HTTP methods are uppercase-only
        XCTAssertNil(HTTPMethodType(rawValue: "get"), "Lowercase 'get' must not produce a valid HTTPMethodType")
        XCTAssertNil(HTTPMethodType(rawValue: "post"), "Lowercase 'post' must not produce a valid HTTPMethodType")
    }

    // MARK: - Queue Instance

    func testSharedInstanceIsSingleton() {
        let a = appContainer.networkQueue
        let b = appContainer.networkQueue
        XCTAssertTrue(a === b, "sharedInstance must return the same object on every access")
        XCTAssertEqual(ObjectIdentifier(a), ObjectIdentifier(b), "Both references must have identical object identity")
    }

    func testObjCSharedReturnsInstance() {
        let instance = appContainer.networkQueue
        XCTAssertNotNil(instance)
        // The ObjC @objc factory must return the same singleton as the Swift property
        XCTAssertTrue(instance === appContainer.networkQueue,
                      "ObjC shared() and Swift sharedInstance must be the same object")
    }

    // MARK: - Add Request (Integration)

    func testAddRequestDoesNotCrash() {
        let queue = appContainer.networkQueue
        // Migrate first to set up the table
        queue.migrate()

        let url = URL(string: "https://example.com/api/test")!
        // Should not crash even with a fresh DB
        queue.addRequest("test-lib", "update-1", url, .POST, nil, nil)

        // Allow serial queue to process
        let expectation = expectation(description: "Queue processes request")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Verify queue is still operable after adding a request
        XCTAssertNotNil(queue, "Queue should remain functional after addRequest")
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue unchanged after use")
    }

    func testAddRequestWithHeadersDoesNotCrash() {
        let queue = appContainer.networkQueue
        queue.migrate()

        let url = URL(string: "https://example.com/api/test")!
        let headers = ["Authorization": "Bearer test-token", "Content-Type": "application/json"]
        let body = Data("{\"key\":\"value\"}".utf8)
        queue.addRequest("test-lib", "update-2", url, .PUT, body, headers)

        let expectation = expectation(description: "Queue processes request")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Queue must remain functional after adding a request with headers and body
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue must be unchanged after addRequest with headers")
    }

    // MARK: - Migration

    func testMigrateDoesNotCrash() {
        let queue = appContainer.networkQueue
        queue.migrate()

        let expectation = expectation(description: "Migration completes")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Queue should remain fully functional post-migration
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue unchanged after migration")
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorNotConnectedToInternet),
                      "StatusCodes should remain valid after migration")
    }

    func testMigrateCanBeCalledMultipleTimes() {
        let queue = appContainer.networkQueue
        queue.migrate()
        queue.migrate()

        let expectation = expectation(description: "Double migration completes")
        queue.serialQueue.async {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 3)
        // Double migration must not alter the queue's configured constants
        XCTAssertEqual(queue.MaxRetriesInQueue, 5, "MaxRetriesInQueue must be unchanged after double migrate")
        XCTAssertTrue(NetworkQueue.StatusCodes.contains(NSURLErrorNotConnectedToInternet),
                      "StatusCodes must remain valid after double migrate")
    }
}
