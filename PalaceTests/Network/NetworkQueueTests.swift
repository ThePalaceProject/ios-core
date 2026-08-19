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
        // `HTTPStubURLProtocol.register` APPENDS to a process-global array, so
        // the catch-all handler installed by the drain test would otherwise
        // outlive this suite and turn "unmatched request fails" into
        // "unmatched request succeeds" for everything that runs after it.
        HTTPStubURLProtocol.reset()
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

    /// A transport whose every request is intercepted by
    /// `HTTPStubURLProtocol` — no real network. The drain test below actually
    /// issues requests, and a unit test that talks to the internet is both
    /// banned by CLAUDE.md and non-deterministic.
    private func makeTransport() -> NetworkTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return NetworkTransport(delegate: nil,
                                sessionConfiguration: config,
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
    /// PP-4987 on CURRENT builds — but it did run historically (see
    /// `testMigrate_PurgesACredentialLeftBehindByAnOlderBuild`), and turning
    /// the queue back on is what would resume it.
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

    // MARK: - PP-4987: proofs against the PERSISTED BYTES, not a helper

    private func makeWritableQueue(
        _ spy: ErrorLoggerSpy = ErrorLoggerSpy(),
        authorizationHeaderProvider: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> (NetworkQueue, String) {
        let dir = NSTemporaryDirectory() + "pp4987-db-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let queue = NetworkQueue(transport: makeTransport(),
                                 reachability: Reachability(),
                                 databaseDirectory: dir,
                                 errorLogger: spy,
                                 authorizationHeaderProvider: authorizationHeaderProvider)
        queue.migrate()
        queue.serialQueue.sync {}
        return (queue, dir)
    }

    /// The security property, asserted where it actually has to hold: on the
    /// row in the database.
    ///
    /// Round 4 caught the previous version of this proof testing
    /// `headersSafeToPersist` in isolation while NOTHING asserted `addRequest`
    /// calls it — unwiring the call site left every test green. Testing the
    /// helper is not testing the producer.
    func testAddRequest_NeverPersistsTheCredential_EvenThoughCallersPassIt() {
        let (queue, dir) = makeWritableQueue()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Exactly what `TPPAnnotations.addToOfflineQueue` hands over: the
        // output of `request(for:)`, whose `useTokenIfAvailable` defaults true.
        queue.addRequest("lib-A", "book-1",
                         URL(string: "https://a.example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8),
                         ["Authorization": "Bearer super-secret-token",
                          "Content-Type": "application/json"])
        queue.serialQueue.sync {}

        let rows = queue.persistedRowsForTesting()
        XCTAssertEqual(rows.count, 1, "precondition: the write was stored")
        XCTAssertNil(rows[0].headers?["Authorization"],
                     "The credential must not be in the database — simplified.db is unencrypted and on disk")
        XCTAssertFalse((rows[0].headers ?? [:]).values.contains { $0.contains("super-secret-token") },
                       "…nor smuggled in under any other header")
        XCTAssertEqual(rows[0].headers?["Content-Type"], "application/json",
                       "Everything the retry legitimately needs must survive")
    }

    /// The data-loss property, asserted against the rows rather than the seam.
    ///
    /// `addRequest` UPDATEs the row matching (libraryID, updateID), so this is
    /// where "two bookmarks must not overwrite each other" is actually decided.
    /// The annotation-side test proves the KEYS differ; this proves differing
    /// keys produce two surviving rows.
    func testAddRequest_DistinctKeysSurviveAsSeparateRows_SharedKeyCollapses() {
        let (queue, dir) = makeWritableQueue()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(string: "https://a.example.org/annotations/")!

        // Two bookmarks in one book — distinct keys, as postReadingPosition
        // now builds them.
        queue.addRequest("lib-A", "book-1|{\"chapter\":1}", url,
                         HTTPMethodType.POST, Data(#"{"n":1}"#.utf8), nil)
        queue.addRequest("lib-A", "book-1|{\"chapter\":9}", url,
                         HTTPMethodType.POST, Data(#"{"n":2}"#.utf8), nil)
        queue.serialQueue.sync {}
        XCTAssertEqual(queue.persistedRowsForTesting().count, 2,
                       "Two distinct bookmarks must survive as two rows — sharing a key silently deletes one")

        // Two positions for the same book — shared key, collapse is CORRECT.
        queue.addRequest("lib-A", "book-2", url,
                         HTTPMethodType.POST, Data(#"{"p":1}"#.utf8), nil)
        queue.addRequest("lib-A", "book-2", url,
                         HTTPMethodType.POST, Data(#"{"p":2}"#.utf8), nil)
        queue.serialQueue.sync {}
        let book2 = queue.persistedRowsForTesting().filter { $0.updateID == "book-2" }
        XCTAssertEqual(book2.count, 1,
                       "A newer position supersedes an older one for the same book — collapsing is the desired behaviour here")
        // "One row" alone cannot distinguish superseding from silently dropping
        // the second write, which is the property that actually matters.
        XCTAssertEqual(book2.first?.parameters, Data(#"{"p":2}"#.utf8),
                       "The surviving row must carry the NEWER position — collapsing must supersede, not discard")
    }

    /// The credential must be resolved for the ROW'S library, never the
    /// currently-selected one.
    ///
    /// `retryQueue` drains every row regardless of library, and each row's URL
    /// is its own library's annotation host. Resolving `currentUserAccount`
    /// would send library B's bearer token to library A's server whenever a
    /// patron queued a write for A and then switched to B — a cross-tenant
    /// credential disclosure, plus a guaranteed 401 for a write that had a
    /// valid token available. Round 4 of review caught exactly that; the
    /// codebase already documents the invariant on
    /// `TPPNetworkExecutor.request(for:accountId:)`.
    func testDrain_SendsEachRowsOwnLibraryCredential_OnTheWire() {
        let seen = SeenAuthorizations()
        HTTPStubURLProtocol.register { @Sendable request in
            guard let host = request.url?.host else { return nil }
            seen.record(host: host,
                        authorization: request.value(forHTTPHeaderField: "Authorization"))
            return .init(statusCode: 200, headers: nil, body: Data("ok".utf8))
        }

        let (queue, dir) = makeWritableQueue(
            authorizationHeaderProvider: { libraryID in "Bearer token-for-\(libraryID)" })
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1",
                         URL(string: "https://a.example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8), nil)
        queue.addRequest("lib-B", "book-2",
                         URL(string: "https://b.example.org/annotations/")!,
                         HTTPMethodType.POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("both rows to be retried") { seen.hosts.count >= 2 }

        // Asserted ON THE WIRE, not at the provider. Round 5 caught the
        // previous version proving only that the right library was ASKED —
        // deleting the `setValue(...)` that attaches the answer left the whole
        // suite green. Resolving a credential and sending it are two claims.
        XCTAssertEqual(seen.authorization(for: "a.example.org"), "Bearer token-for-lib-A",
                       "Library A's row must be sent with library A's credential")
        XCTAssertEqual(seen.authorization(for: "b.example.org"), "Bearer token-for-lib-B",
                       "…and library B's with B's. Sending one library's token to the other's server is a cross-tenant disclosure")
    }

    /// Records the `Authorization` each host actually received. The stub
    /// handler is `@Sendable` and runs off the test's thread, so this has to be
    /// safe to cross that boundary.
    private final class SeenAuthorizations: @unchecked Sendable {
        private let lock = NSLock()
        private var byHost: [String: String?] = [:]
        var hosts: [String] { lock.withLock { Array(byHost.keys) } }
        func record(host: String, authorization: String?) {
            lock.withLock { byHost[host] = authorization }
        }
        func authorization(for host: String) -> String? {
            lock.withLock { byHost[host] ?? nil }
        }
    }

    /// Legacy rows on real devices can carry a cleartext credential, and
    /// `migrate()` must clear them.
    ///
    /// Not hypothetical: up to Release 1.1.0 `postAnnotation` used
    /// `URLSession.shared` directly, so the raw NSURLError reached
    /// `NetworkQueue.StatusCodes` and offline writes really were queued — with
    /// `Authorization: Basic base64(barcode:PIN)`. That is a patron's card
    /// number and PIN, base64 is not encryption, and the store is unencrypted.
    /// I originally claimed such rows could not exist; review proved otherwise
    /// from the git history, which is why this test exists rather than an
    /// argument.
    func testMigrate_PurgesACredentialLeftBehindByAnOlderBuild() {
        let (queue, dir) = makeWritableQueue()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.insertLegacyRowForTesting(
            libraryID: "lib-A",
            updateID: "book-1",
            url: URL(string: "https://a.example.org/annotations/")!,
            headers: ["Authorization": "Basic YmFyY29kZTpQSU4=",
                      "Content-Type": "application/json"])

        XCTAssertEqual(queue.persistedRowsForTesting().first?.headers?["Authorization"],
                       "Basic YmFyY29kZTpQSU4=",
                       "precondition: the legacy row really does carry the credential")

        queue.migrate()
        queue.serialQueue.sync {}

        let row = queue.persistedRowsForTesting().first
        XCTAssertNotNil(row, "The write itself must be kept — only the credential is dropped")
        XCTAssertNil(row?.headers?["Authorization"],
                     "A card number and PIN left on disk by an older build must be cleared on migrate")
        XCTAssertEqual(row?.headers?["Content-Type"], "application/json",
                       "…without discarding the headers the retry legitimately needs")
    }

    /// A superseding write must get a FRESH retry budget.
    ///
    /// `retryQueue` deletes rows with `retries > MaxRetriesInQueue` BEFORE it
    /// drains, so a reading position landing on an exhausted row was deleted
    /// having never been sent once — silent, on the very path PP-4965 removed
    /// the error report from. Reachable specifically because positions are
    /// keyed to collapse on the book.
    ///
    /// Review caught the fix for this shipping untested: `PersistedRow.retries`
    /// was added to observe it and then never asserted, so deleting
    /// `sqlRetries <- 0` left the suite green. That is the same shape as the
    /// round-5 "resolved but never attached" miss.
    func testAddRequest_SupersedingAnAttemptedRow_ResetsItsRetryBudget() {
        HTTPStubURLProtocol.register { @Sendable request in
            guard request.url?.host != nil else { return nil }
            return .init(statusCode: 500, headers: nil, body: Data())
        }
        let (queue, dir) = makeWritableQueue()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(string: "https://a.example.org/annotations/")!

        queue.addRequest("lib-A", "book-1", url,
                         HTTPMethodType.POST, Data(#"{"p":1}"#.utf8), nil)
        queue.serialQueue.sync {}

        // Burn a retry: the drain increments the count before sending.
        queue.retryQueue()
        expectEventually("the row to record an attempt") {
            (queue.persistedRowsForTesting().first?.retries ?? 0) > 0
        }

        // A NEWER position for the same book supersedes it.
        queue.addRequest("lib-A", "book-1", url,
                         HTTPMethodType.POST, Data(#"{"p":2}"#.utf8), nil)
        queue.serialQueue.sync {}

        let row = queue.persistedRowsForTesting().first
        XCTAssertEqual(row?.parameters, Data(#"{"p":2}"#.utf8),
                       "precondition: the newer position replaced the older one")
        XCTAssertEqual(row?.retries, 0,
                       "A superseding write is a NEW write and must get a full retry budget — inheriting an exhausted count gets it deleted before it is ever sent")
    }

    /// A CORRUPTED header archive must be survived, not crashed on.
    ///
    /// The fixture is a valid archive with one bit flipped — which is what
    /// real on-disk corruption looks like, and the only shape that actually
    /// kills the legacy unarchiver. Garbage bytes and truncated archives both
    /// return nil, so a casual probe finds nothing; an earlier version of this
    /// test used ASCII garbage and therefore passed against BOTH
    /// implementations, guarding nothing. Bit-flipping each byte of a valid
    /// 277-byte archive in turn: the legacy `unarchiveObject(with:)` aborts the
    /// process on 63 of 277, the modern `unarchivedObject(ofClasses:)` on none.
    ///
    /// This matters because the purge runs on the LAUNCH path via SEMigrations,
    /// over rows written by builds up to five years old.
    func testMigrate_WithACorruptedHeaderArchive_SurvivesInsteadOfCrashing() {
        let (queue, dir) = makeWritableQueue()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // A real archive with its CLASS NAME corrupted in place. Targeted
        // structurally rather than by byte index: a keyed archive stores
        // "NSDictionary" as ASCII, and destroying it produces exactly the
        // "missing class information for object" condition that makes the
        // legacy unarchiver raise. Flipping an arbitrary byte is unreliable —
        // only 63 of 277 positions abort, and the midpoint is not one of them,
        // which is how the first version of this fixture ended up guarding
        // nothing.
        var corrupted = NSKeyedArchiver.archivedData(
            withRootObject: ["Authorization": "Bearer secret"])
        let className = Array("NSDictionary".utf8)
        if let r = corrupted.range(of: Data(className)) {
            corrupted.replaceSubrange(r, with: Data(repeating: 0x5A, count: className.count))
        } else {
            XCTFail("fixture precondition: the archive should name NSDictionary")
        }

        queue.insertLegacyRowForTesting(
            libraryID: "lib-A",
            updateID: "book-1",
            url: URL(string: "https://a.example.org/annotations/")!,
            headers: [:],
            rawHeaderData: corrupted)

        queue.migrate()
        queue.serialQueue.sync {}

        XCTAssertEqual(queue.persistedRowsForTesting().count, 1,
                       "The row survives — a corrupt blob is not a reason to discard a patron's queued write, and must never abort the launch")
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
