//
//  NetworkQueueTokenRefreshTests.swift
//  PalaceTests
//
//  A queued request that comes back 401 on drain refreshes the row's
//  library token through the executor's single-flight refresh, then resends.
//

import XCTest
import PalaceNetwork
import PalaceCatalog
@testable import Palace

@MainActor
final class NetworkQueueTokenRefreshTests: XCTestCase {

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        GatedURLProtocol.reset()
        ChallengeLog.resetShared()
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
        XCTAssertEqual(refresher.presentsSignIn, [false],
                       "A background drain must not raise the sign-in sheet")
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

    /// A row that 401s after its library's refresh already failed this drain is
    /// kept without another refresh, and the next drain still runs.
    func testDrain_RowHits401AfterItsLibrarysRefreshFailed_IsKeptAndTheNextDrainRuns() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .failure)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        GatedURLProtocol.reset()

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/first")!,
                         .POST, Data("{}".utf8), nil)
        queue.addRequest("lib-A", "book-2", URL(string: "https://a.example.org/annotations/gated")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the first row's refresh to fail") { refresher.libraries.count == 1 }
        settle(queue)
        GatedURLProtocol.open()
        expectEventually("the gated row to be refused") { GatedURLProtocol.answered == 1 }
        settle(queue)

        XCTAssertEqual(refresher.libraries, ["lib-A"], "No second refresh after the first failed")
        XCTAssertEqual(queue.persistedRowsForTesting().count, 2)

        queue.retryQueue()
        expectEventually("the next drain to send both rows again") {
            server.requestCount == 2 && GatedURLProtocol.answered == 2
        }
    }

    // MARK: - Refresh slot held elsewhere, non-token libraries, timeouts

    /// Right after reconnect another request may already be refreshing. The
    /// rows are kept without spending a retry: their credentials were not refused.
    func testDrain_WhenAnotherRefreshHoldsTheSlot_KeepsRowsWithoutSpendingARetry() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .inProgressElsewhere)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        for book in ["book-1", "book-2"] {
            queue.addRequest("lib-A", book, URL(string: "https://a.example.org/annotations/\(book)")!,
                             .POST, Data("{}".utf8), nil)
        }
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("both rows to be refused") { server.requestCount == 2 }
        settle(queue)

        XCTAssertEqual(refresher.libraries, ["lib-A"], "One attempt per library per drain")
        XCTAssertEqual(queue.persistedRowsForTesting().map(\.retries), [0, 0],
                       "A refresh that could not start is not the rows' failure")
        XCTAssertEqual(server.requestCount, 2, "No resend without a new token")
    }

    /// A library that cannot exchange its card for a token is not sent to the
    /// executor, which would only log a missing-credentials error every drain.
    func testDrain_On401_ForALibraryThatCannotRefresh_DoesNotAskTheExecutor() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher,
                                     canRefreshToken: { _ in false })
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the row to be refused") { server.requestCount == 1 }
        settle(queue)

        XCTAssertEqual(refresher.libraries, [])
        XCTAssertEqual(queue.persistedRowsForTesting().map(\.retries), [1])
    }

    /// A refresh whose completion never arrives releases the drain after the
    /// timeout, so the next reconnect can drain again; the late completion is ignored.
    func testDrain_RefreshNeverCompletes_TimesOutAndALateCompletionIsIgnored() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"), holdsCompletion: true)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher, refreshTimeout: 0.3)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the refresh to start") { refresher.libraries.count == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        settle(queue)

        queue.retryQueue()
        expectEventually("the next drain to run after the timeout") { server.requestCount == 2 }
        expectEventually("the next drain's own refresh to start") { refresher.libraries.count == 2 }

        // The first drain's refresh finally answers; the second is still held.
        refresher.releaseFirst()
        settle(queue)
        XCTAssertEqual(server.authorizations(for: "a.example.org").filter { $0 == "Bearer new" }.count, 0,
                       "A completion for a timed-out refresh must not resend anything")
        XCTAssertEqual(queue.persistedRowsForTesting().count, 1)
    }

    /// A reconnect while a refresh is in flight does not start a second drain.
    func testDrain_SecondDrainWhileRefreshInFlight_DoesNotSendOrRefreshAgain() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"), holdsCompletion: true)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        queue.addRequest("lib-A", "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}

        queue.retryQueue()
        expectEventually("the refresh to start") { refresher.libraries.count == 1 }
        queue.retryQueue()
        settle(queue)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(refresher.libraries.count, 1)

        refresher.release()
        expectEventually("the row to be delivered") { queue.persistedRowsForTesting().isEmpty }
        XCTAssertEqual(server.requestCount, 2)
    }

    // MARK: - Supersede during a refresh or an in-flight send

    /// A newer write that replaces the row while its refresh is in flight is
    /// not overwritten by a resend of the old body.
    func testDrain_RowSupersededDuringRefresh_IsNotResentWithTheOldBodyOrDeleted() {
        let tokens = TokenBox(["lib-A": "old"])
        let server = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"), holdsCompletion: true)
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(string: "https://a.example.org/annotations/")!

        queue.addRequest("lib-A", "book-1", url, .POST, Data(#"{"p":1}"#.utf8), nil)
        queue.serialQueue.sync {}
        queue.retryQueue()
        expectEventually("the refresh to start") { refresher.libraries.count == 1 }

        queue.addRequest("lib-A", "book-1", url, .POST, Data(#"{"p":2}"#.utf8), nil)
        queue.serialQueue.sync {}
        refresher.release()
        settle(queue)

        XCTAssertEqual(server.requestCount, 1, "The old body is not resent")
        XCTAssertEqual(queue.persistedRowsForTesting().map(\.parameters), [Data(#"{"p":2}"#.utf8)],
                       "The newer write stays queued")

        queue.retryQueue()
        expectEventually("the newer write to be delivered") { queue.persistedRowsForTesting().isEmpty }
        XCTAssertEqual(server.bodies(for: "a.example.org").last, Data(#"{"p":2}"#.utf8))
    }

    /// A delivered request does not delete a newer write that superseded its
    /// row while it was on the wire.
    func testDrain_RowSupersededWhileSendIsInFlight_KeepsTheNewerWrite() {
        let tokens = TokenBox(["lib-A": "new"])
        _ = StubServer(acceptedToken: "new")
        let refresher = SpyRefresher(tokens: tokens, outcome: .success(newToken: "new"))
        let (queue, dir) = makeQueue(tokens: tokens, refresher: refresher)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        GatedURLProtocol.reset()
        GatedURLProtocol.setStatus(200)
        let url = URL(string: "https://a.example.org/annotations/gated")!

        queue.addRequest("lib-A", "book-1", url, .POST, Data(#"{"p":1}"#.utf8), nil)
        queue.serialQueue.sync {}
        queue.retryQueue()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        queue.addRequest("lib-A", "book-1", url, .POST, Data(#"{"p":2}"#.utf8), nil)
        queue.serialQueue.sync {}

        GatedURLProtocol.open()
        expectEventually("the first send to be answered") { GatedURLProtocol.answered == 1 }
        settle(queue)

        XCTAssertEqual(queue.persistedRowsForTesting().map(\.parameters), [Data(#"{"p":2}"#.utf8)],
                       "Deleting by row id alone would drop the newer write")
    }

    // MARK: - Challenge dispositions

    /// Server trust is left to the system and never consults the row's card and PIN.
    func testRowChallengeResponder_ServerTrust_DefaultHandlingWithoutReadingCredentials() async {
        ChallengeLog.resetShared()
        let responder = RowChallengeResponder(credentials: RecordingCredentials("lib-A-patron"))
        let space = URLProtectionSpace(host: "a.example.org", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil,
                                                   error: nil, sender: IgnoringChallengeSender())
        let task = URLSession.stubbedSession().dataTask(with: URL(string: "https://a.example.org/")!)

        let (disposition, credential) = await responder.urlSession(URLSession.stubbedSession(),
                                                                   task: task,
                                                                   didReceive: challenge)

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
        XCTAssertEqual(ChallengeLog.shared.entries, [], "Server trust must not read the card and PIN")
    }

    /// A Basic challenge is answered with the row's library credential.
    func testRowChallengeResponder_Basic_UsesTheRowsCredential() async {
        ChallengeLog.resetShared()
        let responder = RowChallengeResponder(credentials: RecordingCredentials("lib-A-patron"))
        let space = URLProtectionSpace(host: "a.example.org", port: 443, protocol: "https", realm: "library",
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil,
                                                   error: nil, sender: IgnoringChallengeSender())
        let task = URLSession.stubbedSession().dataTask(with: URL(string: "https://a.example.org/")!)

        let (disposition, credential) = await responder.urlSession(URLSession.stubbedSession(),
                                                                   task: task,
                                                                   didReceive: challenge)

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertEqual(credential?.user, "lib-A-patron")
    }

    // MARK: - Production wiring (`NetworkQueue.live`)

    /// The selected library is B; a row for A must be answered with A's
    /// credentials. Binding the challenge to `currentUserAccount` is the leak.
    func testLive_ChallengeCredentialsComeFromTheRowsLibrary() {
        let libraries = TwoLibraries()
        libraries.selected = libraries.uuidB
        let (queue, _, dir) = makeLiveQueue(libraries)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let answer = queue.challengeCredentialsForTesting(libraryID: libraries.uuidA)

        XCTAssertTrue(answer === libraries.accountA, "Library A's row is answered with A's account")
        XCTAssertEqual(answer?.username, "userA")
    }

    func testLive_RefreshesThroughTheExecutor() {
        let libraries = TwoLibraries()
        let (queue, executor, dir) = makeLiveQueue(libraries)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        XCTAssertTrue(queue.tokenRefresherForTesting === executor,
                      "The queue must use the executor's single-flight refresh")
    }

    /// Mirrors the responder: a token library with a stored card and PIN can
    /// refresh; one without a token endpoint or without a card cannot.
    func testLive_CanRefreshToken_OnlyForTokenLibrariesWithStoredCredentials() {
        let libraries = TwoLibraries()
        let (queue, _, dir) = makeLiveQueue(libraries)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        XCTAssertTrue(queue.canRefreshTokenForTesting(libraryID: libraries.uuidA))
        XCTAssertFalse(queue.canRefreshTokenForTesting(libraryID: libraries.uuidNoAuth),
                       "No auth definition, nothing to refresh")
        XCTAssertFalse(queue.canRefreshTokenForTesting(libraryID: libraries.uuidNoCard),
                       "A token library with no stored card cannot get a new token")
        XCTAssertFalse(queue.canRefreshTokenForTesting(libraryID: libraries.uuidBasic),
                       "A basic-auth library has a card and PIN but no token to refresh")
    }

    /// End to end through the real executor: library A's row 401s while B is
    /// selected, A's token endpoint is called once, and the row goes out with A's new token.
    func testLive_QueuedRowFor401_RefreshesItsOwnLibraryAndIsDelivered() {
        let libraries = TwoLibraries()
        libraries.selected = libraries.uuidB
        let (queue, _, dir) = makeLiveQueue(libraries)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let tokenCalls = SeenHosts()
        let annotationAuth = SeenHosts()
        HTTPStubURLProtocol.register { @Sendable [libraries] request in
            guard let url = request.url, let host = url.host else { return nil }
            if url == libraries.tokenURL_A || url == libraries.tokenURL_B {
                tokenCalls.record(host)
                return .init(statusCode: 200, headers: nil, body: Data(
                    #"{"access_token":"freshA","token_type":"Bearer","expires_in":3600}"#.utf8))
            }
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? "none"
            annotationAuth.record(auth)
            return .init(statusCode: auth == "Bearer freshA" ? 200 : 401, headers: nil, body: Data())
        }

        queue.addRequest(libraries.uuidA, "book-1", URL(string: "https://a.example.org/annotations/")!,
                         .POST, Data("{}".utf8), nil)
        queue.serialQueue.sync {}
        queue.retryQueue()
        expectEventually("the row to be delivered") { queue.persistedRowsForTesting().isEmpty }

        XCTAssertEqual(tokenCalls.values, [libraries.tokenURL_A.host!], "Only A's token endpoint")
        XCTAssertEqual(annotationAuth.values, ["Bearer bearerA", "Bearer freshA"])
        XCTAssertEqual(libraries.accountB.authToken, "bearerB", "The selected library is untouched")
    }

    // MARK: - Executor: sign-in sheet after a refused queue refresh
    //
    // The completions below are `@Sendable`: the executor calls them from the
    // cooperative pool, and a closure formed in this `@MainActor` class would
    // otherwise be main-actor isolated and trap under actor-isolation checks.

    /// A queue refresh refused by the token endpoint marks the credentials
    /// stale but does not raise the sign-in sheet.
    func testExecutorRefresh_RefusedWithoutSignInSheet_MarksStaleAndPresentsNothing() async {
        let libraries = TwoLibraries()
        let executor = makeExecutor(libraries)
        let presented = LockIsolated(0)
        executor.presentSignInAfterRefusedRefresh = { presented.withValue { $0 += 1 } }
        HTTPStubURLProtocol.register { @Sendable [libraries] request in
            request.url == libraries.tokenURL_A ? .init(statusCode: 401, headers: nil, body: Data("no".utf8)) : nil
        }

        let done = expectation(description: "refresh finished")
        executor.refreshTokenAndResume(task: nil, accountId: libraries.uuidA,
                                       presentsSignInOnFailure: false) { @Sendable _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(libraries.accountA.authState, .credentialsStale)
        XCTAssertEqual(presented.value, 0)
    }

    /// Control for the test above: the default still raises the sheet for the
    /// selected library, so the seam is the one the executor really calls.
    func testExecutorRefresh_RefusedByDefault_PresentsTheSignInSheet() async {
        let libraries = TwoLibraries()
        let executor = makeExecutor(libraries)
        let presented = LockIsolated(0)
        executor.presentSignInAfterRefusedRefresh = { presented.withValue { $0 += 1 } }
        HTTPStubURLProtocol.register { @Sendable [libraries] request in
            request.url == libraries.tokenURL_A ? .init(statusCode: 401, headers: nil, body: Data("no".utf8)) : nil
        }

        let done = expectation(description: "refresh finished")
        executor.refreshTokenAndResume(task: nil, accountId: libraries.uuidA) { @Sendable _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(presented.value, 1)
    }

    /// The sheet is only for the selected library: a refused refresh for
    /// another library marks it stale without interrupting the patron.
    func testExecutorRefresh_RefusedForANonSelectedLibrary_PresentsNothing() async {
        let libraries = TwoLibraries()
        libraries.selected = libraries.uuidB
        let executor = makeExecutor(libraries)
        let presented = LockIsolated(0)
        executor.presentSignInAfterRefusedRefresh = { presented.withValue { $0 += 1 } }
        HTTPStubURLProtocol.register { @Sendable [libraries] request in
            request.url == libraries.tokenURL_A ? .init(statusCode: 401, headers: nil, body: Data("no".utf8)) : nil
        }

        let done = expectation(description: "refresh finished")
        executor.refreshTokenAndResume(task: nil, accountId: libraries.uuidA) { @Sendable _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(libraries.accountA.authState, .credentialsStale)
        XCTAssertEqual(presented.value, 0)
    }

    /// A `task: nil` refresh that finds the slot taken says so, which is how
    /// the queue tells "not tried" from "refused".
    func testExecutorRefresh_SlotAlreadyHeld_ReportsInProgress() async {
        let libraries = TwoLibraries()
        let executor = makeExecutor(libraries)
        let claimed = await executor.claimTokenRefreshSlotForTesting()
        XCTAssertTrue(claimed, "precondition")

        let done = expectation(description: "refresh answered")
        let inProgress = LockIsolated<Bool?>(nil)
        executor.refreshTokenAndResume(task: nil, accountId: libraries.uuidA,
                                       presentsSignInOnFailure: false) { @Sendable result in
            if case .failure(let error, _) = result {
                inProgress.withValue { $0 = (error as NSError).userInfo[TPPNetworkExecutor.refreshInProgressKey] as? Bool }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(inProgress.value, true)
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

        // Only credential reads are asserted; when the stub load ends is timing.
        XCTAssertEqual(ChallengeLog.shared.entries.filter { $0.hasPrefix("asked:") }, ["asked:lib-A-patron"],
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

    private func makeQueue(tokens: TokenBox,
                           refresher: SpyRefresher,
                           canRefreshToken: @escaping @Sendable (String) -> Bool = { _ in true },
                           refreshTimeout: TimeInterval = NetworkQueue.defaultRefreshTimeout) -> (NetworkQueue, String) {
        let dir = NSTemporaryDirectory() + "queue-401-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedURLProtocol.self, HTTPStubURLProtocol.self]
        let transport = NetworkTransport(delegate: nil, sessionConfiguration: config, requestTimeout: 5)
        let queue = NetworkQueue(transport: transport,
                                 reachability: Reachability(),
                                 databaseDirectory: dir,
                                 authorizationHeaderProvider: { libraryID in
                                     tokens.token(for: libraryID).map { "Bearer \($0)" }
                                 },
                                 tokenRefresher: refresher,
                                 canRefreshToken: canRefreshToken,
                                 refreshTimeout: refreshTimeout)
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
        ChallengeLog.resetShared()
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

    private func makeExecutor(_ libraries: TwoLibraries) -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return TPPNetworkExecutor(credentialsProvider: nil,
                                  cachingStrategy: .ephemeral,
                                  sessionConfiguration: config,
                                  accountsManager: libraries,
                                  delegateQueue: nil)
    }

    private func makeLiveQueue(_ libraries: TwoLibraries) -> (NetworkQueue, TPPNetworkExecutor, String) {
        let dir = NSTemporaryDirectory() + "queue-live-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let executor = makeExecutor(libraries)
        let queue = NetworkQueue.live(executor: executor,
                                      reachability: Reachability(),
                                      accountsManager: libraries,
                                      databaseDirectory: dir)
        queue.migrate()
        queue.serialQueue.sync {}
        return (queue, executor, dir)
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

/// Two libraries with token auth, plus two that cannot refresh. Each has its
/// own `TPPUserAccountMock`, so reading the wrong library is observable.
private final class TwoLibraries: NSObject, TPPLibraryAccountsProvider, @unchecked Sendable {
    let uuidA = "urn:uuid:queue-library-a"
    let uuidB = "urn:uuid:queue-library-b"
    let uuidNoAuth = "urn:uuid:queue-library-no-auth"
    let uuidNoCard = "urn:uuid:queue-library-no-card"
    let uuidBasic = "urn:uuid:queue-library-basic"
    let tokenURL_A = URL(string: "https://token.a.example.org/token")!
    let tokenURL_B = URL(string: "https://token.b.example.org/token")!
    let accountA = TPPUserAccountMock()
    let accountB = TPPUserAccountMock()
    let accountNoAuth = TPPUserAccountMock()
    let accountNoCard = TPPUserAccountMock()
    let accountBasic = TPPUserAccountMock()
    var selected: String

    override init() {
        selected = uuidA
        super.init()
        accountA._authDefinition = Self.tokenAuth(tokenURL_A)
        accountA.setAuthToken("bearerA", barcode: "userA", pin: "pinA",
                              expirationDate: Date().addingTimeInterval(3600))
        accountA.markLoggedIn()
        accountB._authDefinition = Self.tokenAuth(tokenURL_B)
        accountB.setAuthToken("bearerB", barcode: "userB", pin: "pinB",
                              expirationDate: Date().addingTimeInterval(3600))
        accountB.markLoggedIn()
        accountNoCard._authDefinition = Self.tokenAuth(tokenURL_A)
        accountBasic._authDefinition = Self.basicAuth()
        accountBasic._credentials = .barcodeAndPin(barcode: "userBasic", pin: "pinBasic")
    }

    var tppAccountUUID: String { uuidA }
    var currentAccountId: String? { selected }
    var currentAccount: Account? { nil }
    func account(_ uuid: String) -> Account? { nil }
    func userAccount(for libraryUUID: String) -> TPPUserAccount {
        switch libraryUUID {
        case uuidA: return accountA
        case uuidB: return accountB
        case uuidNoAuth: return accountNoAuth
        case uuidNoCard: return accountNoCard
        case uuidBasic: return accountBasic
        default: return TPPUserAccountMock()
        }
    }
    var currentUserAccount: TPPUserAccount { userAccount(for: selected) }

    private static func basicAuth() -> AccountDetails.Authentication {
        let json = #"{"type": "http://opds-spec.org/auth/basic", "links": []}"#
        // Fixture literal; a decode failure is a broken test, not a runtime path.
        let docAuth = try! JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                                from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }

    private static func tokenAuth(_ tokenURL: URL) -> AccountDetails.Authentication {
        let json = """
        {"type": "http://thepalaceproject.org/authtype/basic-token",
         "links": [{"rel": "authenticate", "href": "\(tokenURL.absoluteString)"}]}
        """
        // Fixture literal; a decode failure is a broken test, not a runtime path.
        let docAuth = try! JSONDecoder().decode(OPDS2AuthenticationDocument.Authentication.self,
                                                from: Data(json.utf8))
        return AccountDetails.Authentication(auth: docAuth)
    }
}

private final class SeenHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func record(_ value: String) { lock.withLock { _values.append(value) } }
}

/// Holds requests whose path ends in `/gated` until `open()`, then answers 401.
/// Polls from the loading thread's run loop rather than blocking it, because
/// custom protocols can share one loading thread.
private final class GatedURLProtocol: URLProtocol {
    private static let state = GateState()
    static var answered: Int { state.answered }
    static func open() { state.setOpen(true) }
    static func setStatus(_ status: Int) { state.setStatus(status) }
    static func reset() { state.reset() }

    private var timer: Timer?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/gated") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let timer = Timer(timeInterval: 0.01, target: self, selector: #selector(poll),
                          userInfo: nil, repeats: true)
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func poll() {
        guard Self.state.isOpen, let url = request.url else { return }
        timer?.invalidate()
        timer = nil
        let response = HTTPURLResponse(url: url, statusCode: Self.state.status, httpVersion: "HTTP/1.1", headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocolDidFinishLoading(self)
        Self.state.recordAnswer()
    }

    override func stopLoading() {
        timer?.invalidate()
        timer = nil
    }
}

private final class GateState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isOpen = false
    private var _answered = 0
    private var _status = 401
    var isOpen: Bool { lock.withLock { _isOpen } }
    var status: Int { lock.withLock { _status } }
    func setStatus(_ value: Int) { lock.withLock { _status = value } }
    var answered: Int { lock.withLock { _answered } }
    func setOpen(_ value: Bool) { lock.withLock { _isOpen = value } }
    func recordAnswer() { lock.withLock { _answered += 1 } }
    func reset() { lock.withLock { _isOpen = false; _answered = 0; _status = 401 } }
}

/// Which credentials a challenge consulted, and when a load ended.
private final class ChallengeLog: @unchecked Sendable {
    static let shared = ChallengeLog()
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
    static func resetShared() { shared.lock.withLock { shared._entries.removeAll() } }
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
    enum Outcome { case success(newToken: String), failure, inProgressElsewhere }

    private let lock = NSLock()
    private let tokens: TokenBox
    private let outcome: Outcome
    private let holdsCompletion: Bool
    private var held: [() -> Void] = []
    private var _libraries: [String] = []
    private var _presentsSignIn: [Bool] = []

    init(tokens: TokenBox, outcome: Outcome, holdsCompletion: Bool = false) {
        self.tokens = tokens
        self.outcome = outcome
        self.holdsCompletion = holdsCompletion
    }

    var libraries: [String] { lock.withLock { _libraries } }
    var presentsSignIn: [Bool] { lock.withLock { _presentsSignIn } }

    func refreshTokenAndResume(task: URLSessionTask?,
                               accountId: String?,
                               presentsSignInOnFailure: Bool,
                               completion: ((NYPLResult<Data>) -> Void)?) {
        let library = accountId ?? ""
        lock.withLock {
            _libraries.append(library)
            _presentsSignIn.append(presentsSignInOnFailure)
        }
        let finish: () -> Void = { [tokens, outcome] in
            switch outcome {
            case .success(let newToken):
                tokens.set(newToken, for: library)
                completion?(.success(Data(), nil))
            case .failure:
                completion?(.failure(NSError(domain: "test", code: 401), nil))
            case .inProgressElsewhere:
                // The shape the executor reports when its slot is taken.
                completion?(.failure(NSError(domain: "test", code: 0, userInfo: [
                    TPPNetworkExecutor.refreshInProgressKey: true
                ]), nil))
            }
        }
        if holdsCompletion {
            lock.withLock { held.append(finish) }
        } else {
            finish()
        }
    }

    /// Completes only the oldest held refresh.
    func releaseFirst() {
        let first = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        first?()
    }

    func release() {
        let pending = lock.withLock { () -> [() -> Void] in
            defer { held.removeAll() }
            return held
        }
        pending.forEach { $0() }
    }
}
