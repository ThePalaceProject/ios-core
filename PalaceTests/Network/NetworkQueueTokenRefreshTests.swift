//
//  NetworkQueueTokenRefreshTests.swift
//  PalaceTests
//
//  A queued request that comes back 401 on drain refreshes the row's
//  library token through the executor's single-flight refresh, then resends.
//

import XCTest
import PalaceNetwork
@testable import Palace

@MainActor
final class NetworkQueueTokenRefreshTests: XCTestCase {

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Refresh then resend

    /// The resend a patron's reading position depends on: a 401 refreshes the
    /// token once and the row goes out again with the new credential.
    func testDrain_On401_RefreshesTheRowsLibraryAndResendsWithTheNewToken() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data(#"{"p":1}"#.utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the row to be delivered") { queue.persistedRowsForTesting().isEmpty }

        XCTAssertEqual(refresher.libraries, ["lib-A"],
                       "One refresh, for the library the row belongs to")
        XCTAssertEqual(server.authorizations(for: "a.example.org"), ["Bearer old", "Bearer new"],
                       "The row is resent once, carrying the refreshed token")
        XCTAssertEqual(server.bodies(for: "a.example.org").last, Data(#"{"p":1}"#.utf8),
                       "The resend carries the queued body, not an empty request")
    }

    /// Several rows draining together must share one refresh, or a backlog of
    /// reading positions becomes a burst of token requests.
    func testDrain_SeveralRowsHit401_TriggersExactlyOneRefreshAndResendsEveryRow() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"), holdsCompletion: true)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        for book in ["book-1", "book-2", "book-3"] {
            queue.addRequest("lib-A", book, URL(string: "https://a.example.org/annotations/\(book)")!,
                             .POST, Data("{}".utf8), nil)
        }
        queue.serialQueue.sync {}

        queue.retryQueue()
        // Hold the refresh open until every row has seen its 401, so all three
        // arrive while it is in flight.
        expectEventually("all three rows to be refused") { server.requestCount == 3 }
        queue.serialQueue.sync {}
        refresher.release()

        expectEventually("every row to be delivered") { queue.persistedRowsForTesting().isEmpty }
        XCTAssertEqual(refresher.libraries, ["lib-A"],
                       "Three 401s from one library in one drain must cause exactly one refresh")
        XCTAssertEqual(server.requestCount, 6, "Each row is sent once, refused, then resent once")
    }

    /// Rows from two libraries refresh each library's own token: refreshing the
    /// current library for another library's row would never fix that row.
    func testDrain_RowsFromTwoLibrariesHit401_RefreshesEachLibraryOnce() {
        let tokens = TokenBox(["lib-A": "old", "lib-B": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.addRequest("lib-B", "book-2", URL(string: "https://b.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("both rows to be delivered") { queue.persistedRowsForTesting().isEmpty }

        XCTAssertEqual(refresher.libraries.sorted(), ["lib-A", "lib-B"])
        XCTAssertEqual(server.authorizations(for: "b.example.org").last, "Bearer new")
    }

    // MARK: - Refresh does not fix it

    /// A failed refresh keeps the row for a later drain without resending it
    /// with the credential the server just refused.
    func testDrain_On401_WhenRefreshFails_KeepsTheRowAndDoesNotResend() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .failure)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the refresh to be attempted") { refresher.libraries.count == 1 }
        settle(queue)

        XCTAssertEqual(server.requestCount, 1, "No resend after a failed refresh")
        XCTAssertEqual(queue.persistedRowsForTesting().map(\.retries), [1],
                       "The row is kept, with this drain counted against its retry budget")
    }

    /// The retry cap still ends a row whose refresh never succeeds, so a
    /// signed-out library cannot keep a row alive forever.
    func testDrain_RefreshKeepsFailing_RowIsDeletedOnceRetriesAreExhausted() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .failure)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        let attempts = queue.MaxRetriesInQueue + 1
        for drain in 1...attempts {
            queue.retryQueue()
            expectEventually("drain \(drain) to attempt a refresh") { refresher.libraries.count == drain }
            settle(queue)
        }
        queue.retryQueue()
        settle(queue)

        XCTAssertTrue(queue.persistedRowsForTesting().isEmpty,
                      "A row past MaxRetriesInQueue is deleted even when every drain ends in a 401")
        XCTAssertEqual(server.requestCount, attempts, "One send per drain, then none once the row is gone")
    }

    /// The refreshed token is refused too: the row is kept and the drain does
    /// not refresh a second time, which would loop for as long as the server says 401.
    func testDrain_ResendAfterRefreshAlso401s_KeepsTheRowWithoutASecondRefresh() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "never")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the resend to be refused") { server.requestCount == 2 }
        settle(queue)

        XCTAssertEqual(refresher.libraries, ["lib-A"], "One refresh per library per drain")
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(queue.persistedRowsForTesting().count, 1, "The row waits for a later drain")
    }

    // MARK: - Other statuses unchanged

    func testDrain_On500_DoesNotRefreshAndKeepsTheRow() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new", rejectionStatus: 500)
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the row to be sent") { server.requestCount == 1 }
        settle(queue)

        XCTAssertEqual(refresher.libraries, [], "Only a 401 means the credential needs refreshing")
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(queue.persistedRowsForTesting().map(\.retries), [1])
    }

    func testDrain_On2xx_DeletesTheRowWithoutRefreshing() {
        let tokens = TokenBox(["lib-A": "new"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the row to be delivered") { queue.persistedRowsForTesting().isEmpty }

        XCTAssertEqual(refresher.libraries, [])
        XCTAssertEqual(server.requestCount, 1)
    }


    // MARK: - Authentication challenges

    /// A Basic challenge on a queued request is answered with the credentials
    /// of the row's library. The session's responder would answer with the
    /// selected library's, sending one library's card and PIN to another's server.
    func testDrain_WhenServerChallenges_AnswersWithTheRowsLibraryNotTheSelectedOne() {
        let (queue, dir) = makeChallengedQueue(rowCredentials: { libraryID in
            RecordingCredentials("\(libraryID)-patron")
        })
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the challenge to be answered") { !ChallengeLog.shared.entries.isEmpty }
        settle(queue)

        XCTAssertEqual(ChallengeLog.shared.entries, ["asked:lib-A-patron"],
                       "Only the row's library is asked; the selected library's credentials are never read")
    }

    /// A row whose library has no credentials declines the challenge rather
    /// than falling back to whichever library is selected.
    func testDrain_WhenRowsLibraryHasNoCredentials_DoesNotAnswerWithTheSelectedLibrary() {
        let (queue, dir) = makeChallengedQueue(rowCredentials: { _ in nil })
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the declined challenge to end the load") {
            ChallengeLog.shared.entries.contains("stopped")
        }

        XCTAssertFalse(ChallengeLog.shared.entries.contains("asked:selected-patron"),
                       "The selected library's credentials must not answer another library's challenge")
    }

    // MARK: - Helpers

    private func makeQueue(tokens: TokenBox, refresher: SpyRefresher) -> (NetworkQueue, String) {
        let dir = NSTemporaryDirectory() + "queue-401-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let transport = NetworkTransport(delegate: nil, sessionConfiguration: config, requestTimeout: 5)
        let queue = NetworkQueue(transport: transport,
                                 reachability: Reachability(),
                                 databaseDirectory: dir,
                                 authorizationHeaderProvider: { libraryID in
                                     tokens.token(for: libraryID).map { "Bearer \($0)" }
                                 },
                                 tokenRefresher: refresher)
        queue.migrate()
        queue.serialQueue.sync {}
        return (queue, dir)
    }


    /// The session delegate is the real responder, whose fallback stands in
    /// for the selected library; the server answers every request with a
    /// Basic challenge.
    private func makeChallengedQueue(
        rowCredentials: @escaping @Sendable (String) -> NYPLBasicAuthCredentialsProvider?
    ) -> (NetworkQueue, String) {
        ChallengeLog.shared.reset()
        let dir = NSTemporaryDirectory() + "queue-challenge-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let responder = TPPNetworkResponder(credentialsProvider: nil,
                                            useFallbackCaching: false,
                                            fallbackCredentialsProvider: { RecordingCredentials("selected-patron") })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BasicChallengeURLProtocol.self]
        config.timeoutIntervalForRequest = 2
        let transport = NetworkTransport(delegate: responder, sessionConfiguration: config, requestTimeout: 2)
        let queue = NetworkQueue(transport: transport,
                                 reachability: Reachability(),
                                 databaseDirectory: dir,
                                 challengeCredentialsProvider: rowCredentials)
        queue.migrate()
        queue.serialQueue.sync {}
        return (queue, dir)
    }

    /// Lets in-flight completions land: the response, the 401 handling and the
    /// refresh completion each hop onto the serial queue.
    private func settle(_ queue: NetworkQueue) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            queue.serialQueue.sync {}
        }
    }

    private func expectEventually(_ what: String,
                                  timeout: TimeInterval = 5.0,
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
}

// MARK: - Test doubles

/// Which credentials a challenge consulted, and when a load ended.
private final class ChallengeLog: @unchecked Sendable {
    static let shared = ChallengeLog()
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
    func reset() { lock.withLock { _entries.removeAll() } }
}

/// Records each read of its username, which is how `TPPBasicAuth` consults it.
private final class RecordingCredentials: NSObject, NYPLBasicAuthCredentialsProvider {
    private let name: String
    init(_ name: String) { self.name = name }
    var username: String? { ChallengeLog.shared.add("asked:\(name)"); return name }
    var pin: String? { "pin" }
}

private final class IgnoringChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

/// Issues an HTTP Basic challenge for every request, as a library server does
/// for a request without valid credentials.
private final class BasicChallengeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let space = URLProtectionSpace(host: host, port: 443, protocol: "https", realm: "library",
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let failure = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1",
                                      headerFields: ["WWW-Authenticate": "Basic realm=\"library\""])
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: failure,
                                                   error: nil, sender: IgnoringChallengeSender())
        client?.urlProtocol(self, didReceive: challenge)
    }
    override func stopLoading() { ChallengeLog.shared.add("stopped") }
}

/// The keychain stand-in: the token each library currently holds.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]
    init(_ tokens: [String: String]) { self.tokens = tokens }
    func token(for libraryID: String) -> String? { lock.withLock { tokens[libraryID] } }
    func set(_ token: String, for libraryID: String) { lock.withLock { tokens[libraryID] = token } }
}

/// Accepts only `Bearer <acceptedToken>`; everything else gets `rejectionStatus`.
private final class StubServer: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(host: String, authorization: String?, body: Data?)] = []

    init(acceptedToken: String, rejectionStatus: Int = 401) {
        HTTPStubURLProtocol.register { @Sendable [self] request in
            guard let host = request.url?.host else { return nil }
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            lock.withLock { seen.append((host, authorization, request.bodyData)) }
            let status = authorization == "Bearer \(acceptedToken)" ? 200 : rejectionStatus
            return .init(statusCode: status, headers: nil, body: Data())
        }
    }

    var requestCount: Int { lock.withLock { seen.count } }
    func authorizations(for host: String) -> [String?] {
        lock.withLock { seen.filter { $0.host == host }.map(\.authorization) }
    }
    func bodies(for host: String) -> [Data?] {
        lock.withLock { seen.filter { $0.host == host }.map(\.body) }
    }
}

/// Stands in for the executor's single-flight refresh. On success it writes the
/// new token where the queue's header provider reads it, as `setAuthToken` does.
private final class SpyRefresher: OfflineQueueTokenRefreshing, @unchecked Sendable {
    enum Outcome { case success(newToken: String), failure }

    private let lock = NSLock()
    private let tokens: TokenBox
    private let outcome: Outcome
    private let holdsCompletion: Bool
    private var held: [() -> Void] = []
    private var _libraries: [String] = []

    init(tokens: TokenBox, outcome: Outcome, holdsCompletion: Bool = false) {
        self.tokens = tokens
        self.outcome = outcome
        self.holdsCompletion = holdsCompletion
    }

    var libraries: [String] { lock.withLock { _libraries } }

    func refreshTokenAndResume(task: URLSessionTask?,
                               accountId: String?,
                               completion: ((NYPLResult<Data>) -> Void)?) {
        let library = accountId ?? ""
        lock.withLock { _libraries.append(library) }
        let finish: () -> Void = { [tokens, outcome] in
            switch outcome {
            case .success(let newToken):
                tokens.set(newToken, for: library)
                completion?(.success(Data(), nil))
            case .failure:
                completion?(.failure(NSError(domain: "test", code: 401), nil))
            }
        }
        if holdsCompletion {
            lock.withLock { held.append(finish) }
        } else {
            finish()
        }
    }

    func release() {
        let pending = lock.withLock { () -> [() -> Void] in
            defer { held.removeAll() }
            return held
        }
        pending.forEach { $0() }
    }
}
