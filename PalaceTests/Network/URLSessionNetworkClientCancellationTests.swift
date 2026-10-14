//
//  URLSessionNetworkClientCancellationTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceNetwork
@testable import Palace

/// Cancelling the Task awaiting `URLSessionNetworkClient.send` must free the
/// request promptly; a held request keeps a connection-pool slot and can starve
/// other feed fetches to the same host (#1116). Each test names the point at
/// which the cancel lands: before dispatch, during a proactive token refresh,
/// or after the request reached the server.
@MainActor
final class URLSessionNetworkClientCancellationTests: XCTestCase {

    /// Per-test path segment: `ScriptedURLProtocol` is process-wide, so a request
    /// left over from another test class must not reach or be counted by this one.
    private let runID = UUID().uuidString
    private lazy var apiURL = URL(string: "https://api.example.com/\(runID)/feed")!
    private lazy var tokenURL = URL(string: "https://token.example.com/\(runID)/oauth/token")!

    override func setUp() async throws {
        try await super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() async throws {
        // Let anything still held unwind so no URLSession task outlives the test.
        ScriptedURLProtocol.release(tokenURL, status: 503, body: nil)
        ScriptedURLProtocol.release(apiURL, status: 503, body: nil)
        ScriptedURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - After dispatch

    /// The plain path, with a token far from expiry so no refresh runs: once the
    /// request is on the wire, cancelling must stop it at URLSession (the
    /// protocol is told to stop loading) and the await must throw promptly.
    func testSend_cancelledAfterDispatch_stopsTheRequestAndThrows() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .hold)
        let started = expectation(description: "request reached the server")
        let stopped = expectation(description: "URLSession stopped the request")
        ScriptedURLProtocol.expectStart(of: apiURL, started)
        ScriptedURLProtocol.expectStop(of: apiURL, stopped)

        let sendTask = makeSendTask(fixture.client, .GET)
        await fulfillment(of: [started], timeout: 5) // STARVE-001-OK: fulfilled by the URLProtocol when the request starts, no fire-and-forget work

        sendTask.cancel()

        await assertThrowsPromptly(sendTask)
        await fulfillment(of: [stopped], timeout: 3) // STARVE-001-OK: URLSession calls stopLoading synchronously with the task cancel
        XCTAssertEqual(ScriptedURLProtocol.startCount(of: tokenURL), 0,
                       "a token far from expiry must not trigger a refresh")
    }

    // MARK: - Before dispatch

    /// A Task already cancelled when `send` is called must not open a
    /// connection, and must throw `CancellationError` as it did before the
    /// client was routed through `execute`.
    func testSend_whenAlreadyCancelled_throwsCancellationErrorWithoutRequesting() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))
        let client = fixture.client
        let url = apiURL

        let sendTask = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await client.send(NetworkRequest(method: .GET, url: url))
        }

        do {
            try await sendTask.value
            XCTFail("a cancelled send must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertEqual(ScriptedURLProtocol.started.count, 0,
                       "no request may reach the server for a Task cancelled before send")
    }

    /// Same, with a near-expiry token: the cancelled send must not start a token
    /// refresh either, since nothing is waiting on its result.
    func testSend_whenAlreadyCancelledWithNearExpiryToken_startsNoRefresh() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 60)
        ScriptedURLProtocol.route(tokenURL, .respond(status: 200, headers: nil,
                                                  body: URLSessionNetworkClientFixture.tokenJSON("refreshed")))
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))
        let client = fixture.client
        let url = apiURL

        let sendTask = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await client.send(NetworkRequest(method: .GET, url: url))
        }

        do {
            try await sendTask.value
            XCTFail("a cancelled send must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        let refreshing = await fixture.executor.isTokenRefreshingForTesting
        XCTAssertFalse(refreshing, "a cancelled send must not claim the refresh slot")
        XCTAssertEqual(ScriptedURLProtocol.started.count, 0,
                       "neither the token endpoint nor the API may be contacted")
    }

    // MARK: - During the proactive refresh

    /// The defect: with a near-expiry token the executor refreshes before it
    /// dispatches, and the callback form handed back no task for that window,
    /// so a cancel was dropped and the await hung until the refresh and the
    /// request both finished. The await must end at the cancel, and the request
    /// must not be sent once the refresh completes.
    func testSend_cancelledDuringTokenRefresh_throwsPromptlyAndNeverSendsTheRequest() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 60)
        ScriptedURLProtocol.route(tokenURL, .hold)
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))
        let refreshStarted = expectation(description: "token refresh reached the server")
        ScriptedURLProtocol.expectStart(of: tokenURL, refreshStarted)

        let sendTask = makeSendTask(fixture.client, .GET)
        await fulfillment(of: [refreshStarted], timeout: 5) // STARVE-001-OK: fulfilled by the URLProtocol when the token request starts

        sendTask.cancel()
        await assertThrowsPromptly(sendTask)

        let apiSent = expectation(description: "API request sent after the cancel")
        apiSent.isInverted = true
        ScriptedURLProtocol.expectStart(of: apiURL, apiSent)
        ScriptedURLProtocol.release(tokenURL, status: 200,
                                 body: URLSessionNetworkClientFixture.tokenJSON("refreshed"))
        // Cancelling one waiter must not abandon the shared refresh.
        let user = fixture.currentUser
        await awaitConditionAsync { user.authToken == "refreshed" }
        let executor = fixture.executor
        await awaitConditionAsync { await !executor.isTokenRefreshingForTesting }
        // Inverted: the window in which a dropped cancel would dispatch.
        await fulfillment(of: [apiSent], timeout: 1) // STARVE-001-OK: inverted expectation bounding a must-not-happen event
        XCTAssertEqual(ScriptedURLProtocol.startCount(of: apiURL), 0,
                       "the cancelled request must not reach the server after the refresh")
    }

    // MARK: - execute, the entry point send relies on

    /// A Task already cancelled when it reaches `execute` with a near-expiry
    /// token gets the cancelled result without starting a refresh that
    /// nobody would wait for.
    func testExecute_whenAlreadyCancelledWithNearExpiryToken_returnsCancelledWithoutRefreshing() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 60)
        ScriptedURLProtocol.route(tokenURL, .respond(status: 200, headers: nil,
                                                     body: URLSessionNetworkClientFixture.tokenJSON("refreshed")))
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))
        let refreshSent = expectation(description: "token request sent for a cancelled request")
        refreshSent.isInverted = true
        ScriptedURLProtocol.expectStart(of: tokenURL, refreshSent)

        let code = await executeCancelled(fixture.executor)

        XCTAssertEqual(code, NSURLErrorCancelled)
        // A refresh started by mistake runs on its own Task after execute
        // returns, so the token request is awaited over a window, not read
        // once.
        await fulfillment(of: [refreshSent], timeout: 1) // STARVE-001-OK: inverted expectation bounding a must-not-happen event
        let refreshing = await fixture.executor.isTokenRefreshingForTesting
        XCTAssertFalse(refreshing, "a cancelled request must not claim the refresh slot")
        XCTAssertEqual(fixture.executor.registeredTaskCount, 0, "no API task may be created")
        XCTAssertEqual(ScriptedURLProtocol.started.count, 0,
                       "neither the token endpoint nor the API may be contacted")
    }

    /// The plain path: a Task already cancelled gets the cancelled result and
    /// no request reaches the server.
    func testExecute_whenAlreadyCancelled_returnsCancelledWithoutRequesting() async {
        let fixture = URLSessionNetworkClientFixture(tokenURL: tokenURL, tokenExpiresIn: 3600)
        ScriptedURLProtocol.route(apiURL, .respond(status: 200, headers: nil, body: Data("ok".utf8)))

        let code = await executeCancelled(fixture.executor)

        XCTAssertEqual(code, NSURLErrorCancelled)
        // Counted at creation: a task resumed and cancelled at once may never
        // reach the URLProtocol, so `started` alone cannot show it was sent.
        XCTAssertEqual(fixture.executor.registeredTaskCount, 0, "no task may be created")
        XCTAssertEqual(ScriptedURLProtocol.started.count, 0, "no request may reach the server")
    }

    // MARK: - Helpers

    /// Runs `execute` in a Task cancelled before the call and returns the
    /// failure's error code, or nil on success. `NYPLResult` is not Sendable,
    /// so only the code leaves the Task.
    private func executeCancelled(_ executor: TPPNetworkExecutor) async -> Int? {
        let url = apiURL
        return await Task<Int?, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            switch await executor.execute(URLRequest(url: url), enableTokenRefresh: true, accountId: nil) {
            case .success: return nil
            case let .failure(error, _): return (error as NSError).code
            }
        }.value
    }

    private func makeSendTask(_ client: URLSessionNetworkClient,
                              _ method: HTTPMethod) -> Task<Void, Error> {
        let url = apiURL
        return Task<Void, Error> {
            _ = try await client.send(NetworkRequest(method: method, url: url))
        }
    }

    /// Waits for `task` to finish after a cancel, failing if it returns a
    /// response or takes longer than `bound` seconds.
    private func assertThrowsPromptly(_ task: Task<Void, Error>,
                                      bound: TimeInterval = 3,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async {
        let outcome = LockIsolated<Result<Void, Error>?>(nil)
        let finished = expectation(description: "send finished after cancel")
        Task {
            do { try await task.value; outcome.value = .success(()) } catch { outcome.value = .failure(error) }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: bound) // STARVE-001-OK: the bound is the property under test (#1116)
        switch outcome.value {
        case .success:
            XCTFail("a cancelled send must throw rather than return a response", file: file, line: line)
        case .failure, nil:
            break
        }
    }
}
