//
//  TPPNetworkExecutorCancellationTests.swift
//  PalaceTests
//
//  `TPPNetworkExecutor`'s async bridges must honour Task cancellation.
//
//  WHY THIS EXISTS. The five async bridges (`GET`, `GET(request:)`, `PUT`,
//  `POST`, `DELETE`) suspend in `withCheckedThrowingContinuation`. A
//  `CheckedContinuation` is resumed only by its completion handler —
//  `Task.cancel()` sets a flag and cannot resume it. So a task suspended in one
//  of these bridges whose HTTP completion never fires is PERMANENTLY
//  uncancellable.
//
//  That is not hypothetical. `AccountRegistryLoader` guards its crawl with
//  eight `Task.isCancelled` checks, but every one of them sits BETWEEN awaits,
//  so a task parked inside the bridge never reaches any of them. The test
//  boundary drain then fails forever, once per test:
//
//      [WS0-DRAIN] cancelAndDrainBackgroundWork TIMED OUT after 3006ms
//                  draining 2 task(s) — crawl did not observe cancellation
//
//  Observed repeating every 3 seconds for 23 minutes in a full-suite run: two
//  leaked crawl tasks made EVERY subsequent test boundary pay a 3s timeout,
//  degrading the suite until it was killed. It presents as a moving "hang"
//  because the cost is cumulative, not located in any one test.
//
//  `URLSessionNetworkClient` already gets this right (`withTaskCancellationHandler`
//  + `CancellableTaskBox`); these bridges never adopted it.
//
//  HOW IT IS TESTED. `TPPNetworkExecutor` builds its own `URLSession` and takes
//  no session injection, so `HTTPStubURLProtocol` cannot reach it. Instead we
//  point it at a real local listener that accepts the connection and never
//  answers — the production failure exactly. The assertions race the awaiting
//  task against a short sleep so a REGRESSION FAILS FAST instead of wedging the
//  bundle, which is the very pathology under test.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Network
import XCTest

@testable import Palace

/// Accepts TCP connections and never writes a byte, so any HTTP request sent to
/// it stays in flight until the client gives up or is cancelled.
private final class NeverRespondingServer: @unchecked Sendable {

    /// Holds accepted connections so the peer stays open — a torn-down peer
    /// would fail the request fast and the test would pass for the wrong reason.
    private final class ConnectionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        func keep(_ c: NWConnection) {
            lock.lock(); defer { lock.unlock() }
            connections.append(c)
        }
        func closeAll() {
            lock.lock(); defer { lock.unlock() }
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private let listener: NWListener
    private let store: ConnectionStore
    private let firstConnection: DispatchSemaphore

    let port: UInt16

    /// Resolves when a request actually reaches the socket. Deterministic —
    /// replaces a fixed sleep, which STARVE-001 correctly rejects: an arbitrary
    /// deadline starves under parallel sim clones, and "the connection arrived"
    /// is the real event we were approximating.
    func awaitFirstConnection() async {
        let sem = firstConnection
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                // Bounded: if the connection never lands, resume anyway so the
                // test fails on its assertion rather than wedging the bundle —
                // wedging is the very pathology under test.
                _ = sem.wait(timeout: .now() + 10)
                c.resume()
            }
        }
    }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        let store = ConnectionStore()

        let ready = DispatchSemaphore(value: 0)
        let firstConnection = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            store.keep(conn)
            firstConnection.signal()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())

        guard ready.wait(timeout: .now() + 5) == .success,
              let bound = listener.port?.rawValue, bound != 0 else {
            listener.cancel()
            throw NSError(domain: "NeverRespondingServer", code: 1)
        }

        self.listener = listener
        self.store = store
        self.firstConnection = firstConnection
        self.port = bound
    }

    func shutdown() {
        store.closeAll()
        listener.cancel()
    }
}

final class TPPNetworkExecutorCancellationTests: XCTestCase {

    private var server: NeverRespondingServer!
    private var executor: TPPNetworkExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try NeverRespondingServer()
        executor = TPPNetworkExecutor(credentialsProvider: nil, cachingStrategy: .fallback)
    }

    override func tearDown() {
        server?.shutdown()
        server = nil
        executor = nil
        super.tearDown()
    }

    private var hangingURL: URL {
        URL(string: "http://127.0.0.1:\(server.port)/never-answers")!
    }

    private enum Outcome: Equatable {
        case cancelled
        case returned
        case failed(String)
        /// The awaiting task did NOT unblock — the defect.
        case stillRunning
    }

    /// Cancels an in-flight bridge call and reports what the awaiting task did,
    /// bounded so a regression fails in seconds rather than hanging the bundle.
    private func outcomeAfterCancelling(
        _ call: @escaping @Sendable (TPPNetworkExecutor) async throws -> Void
    ) async -> Outcome {
        let executor = self.executor!
        let server = self.server!

        let task = Task<Outcome, Never> {
            do {
                try await call(executor)
                return .returned
            } catch is CancellationError {
                return .cancelled
            } catch {
                // A cancelled URLSession task surfaces as NSURLErrorCancelled;
                // that is an honest cancellation too.
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    return .cancelled
                }
                return .failed("\(ns.domain):\(ns.code)")
            }
        }

        // Wait for the REQUEST TO REACH THE SOCKET — an actual event, not a
        // guessed interval. Cancelling before the request is in flight would
        // test the trivial already-cancelled path instead of the defect.
        await server.awaitFirstConnection()
        task.cancel()

        // Race the task against a bound so the RED case is fast and legible.
        return await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return Outcome.stillRunning
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .stillRunning
        }
    }

    func testGET_url_honoursTaskCancellation() async throws {
        let url = hangingURL
        let outcome = await outcomeAfterCancelling { try await _ = $0.GET(url) }
        XCTAssertEqual(
            outcome, .cancelled,
            "GET(_:) must unblock its awaiting Task on cancellation. Suspended in a bare "
                + "withCheckedThrowingContinuation it never will, and the task becomes "
                + "permanently undrainable — the crawl-did-not-observe-cancellation defect."
        )
    }

    func testGETRequest_honoursTaskCancellation() async throws {
        let request = URLRequest(url: hangingURL)
        let outcome = await outcomeAfterCancelling {
            try await _ = $0.GET(request: request, useTokenIfAvailable: false)
        }
        XCTAssertEqual(outcome, .cancelled, "GET(request:) must unblock on cancellation.")
    }

    func testPUT_honoursTaskCancellation() async throws {
        let url = hangingURL
        let outcome = await outcomeAfterCancelling {
            try await _ = $0.PUT(url, useTokenIfAvailable: false)
        }
        XCTAssertEqual(outcome, .cancelled, "PUT must unblock on cancellation.")
    }

    func testPOST_honoursTaskCancellation() async throws {
        let request: URLRequest = {
            var r = URLRequest(url: hangingURL)
            r.httpMethod = "POST"
            return r
        }()
        let outcome = await outcomeAfterCancelling {
            try await _ = $0.POST(request, useTokenIfAvailable: false)
        }
        XCTAssertEqual(outcome, .cancelled, "POST must unblock on cancellation.")
    }

    func testDELETE_honoursTaskCancellation() async throws {
        let request: URLRequest = {
            var r = URLRequest(url: hangingURL)
            r.httpMethod = "DELETE"
            return r
        }()
        let outcome = await outcomeAfterCancelling {
            try await _ = $0.DELETE(request, useTokenIfAvailable: false)
        }
        XCTAssertEqual(outcome, .cancelled, "DELETE must unblock on cancellation.")
    }

    /// Guards the fixture itself. If the local server ever answered, every test
    /// above would pass for the wrong reason — the call would simply complete
    /// before cancellation mattered.
    func testFixture_serverNeverAnswers() async throws {
        let url = hangingURL
        let executor = self.executor!
        let finished = expectation(description: "request settled")
        finished.isInverted = true
        let probe = Task { @Sendable in
            _ = try? await executor.GET(url)
            finished.fulfill()
        }
        // Inverted expectation: the timeout ELAPSING is the assertion (the
        // request must NOT settle). There is no async work to join here; a
        // Task-join seam would invert the meaning of the test.
        await fulfillment(of: [finished], timeout: 2.0)  // STARVE-001-OK: inverted expectation — elapsing IS the assertion; nothing to join
        probe.cancel()
    }
}
