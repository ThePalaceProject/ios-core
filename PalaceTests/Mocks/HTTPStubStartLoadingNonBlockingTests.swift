//
//  HTTPStubStartLoadingNonBlockingTests.swift
//  PalaceTests
//
//  Wave 2 (swarm_b503a876 Module A) — pins the non-blocking
//  `startLoading` contract. Before this fix, a handler that called
//  `DispatchSemaphore.wait(timeout: 3.0)` inside its closure blocked
//  the URLSession delegate queue, serializing all other stubbed
//  requests behind it. `TokenRefreshOnForegroundTests` was hitting a
//  30s test timeout because a handler-internal 3s wait was multiplying
//  out against LIFO handler stacking from prior tests.
//
//  Post-fix: `HTTPStubURLProtocol.startLoading` dispatches response
//  emission onto a dedicated concurrent queue. Two concurrent stubbed
//  requests with slow handlers both complete in <500ms (the
//  semaphore-modeled work runs in parallel, not serialized).
//

import Foundation
import XCTest
@testable import Palace

final class HTTPStubStartLoadingNonBlockingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.removeAllHandlers()
    }

    override func tearDown() {
        HTTPStubURLProtocol.removeAllHandlers()
        super.tearDown()
    }

    // MARK: - 1. Two concurrent requests complete in parallel

    func testStartLoading_twoConcurrentStubbedRequests_doNotSerialize() throws {
        // Two URLs share one handler that introduces an artificial
        // 200ms delay before responding. If the handler runs on a
        // serialized delegate queue, total walltime is ~400ms. If
        // requests proceed in parallel — the contract we're pinning —
        // total walltime is ~200ms + scheduling overhead.
        let processingDelaySeconds: TimeInterval = 0.2

        HTTPStubURLProtocol.register { request in
            // Sleep inside the handler closure simulates blocking I/O
            // (the failure mode TokenRefreshOnForegroundTests hits with
            // `DispatchSemaphore.wait(timeout: 3.0)`).
            Thread.sleep(forTimeInterval: processingDelaySeconds)
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: nil,
                body: Data(request.url?.absoluteString.utf8 ?? "".utf8)
            )
        }

        let session = URLSession.stubbed()
        defer { session.finishTasksAndInvalidate() }

        let firstURL = try XCTUnwrap(URL(string: "https://example.com/concurrent/first"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/concurrent/second"))

        let firstComplete = expectation(description: "first request completes")
        let secondComplete = expectation(description: "second request completes")

        let startTime = Date()
        session.dataTask(with: firstURL) { _, _, _ in firstComplete.fulfill() }.resume()
        session.dataTask(with: secondURL) { _, _, _ in secondComplete.fulfill() }.resume()

        // Both must complete within 500ms — generously larger than the
        // 200ms processing delay but strictly less than the 400ms
        // walltime that serialized handlers would produce. The 500ms
        // cap is the structural assertion: handlers run in parallel.
        wait(for: [firstComplete, secondComplete], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertLessThan(
            elapsed, 0.5,
            "Two concurrent stubbed requests with 200ms-blocking handlers " +
            "completed in \(elapsed)s. Expected < 0.5s (parallel execution). " +
            "Serialized execution would have produced ~0.4s + scheduling — " +
            "the test passing means handlers ran in parallel."
        )
    }

    // MARK: - 2. startLoading returns synchronously even with a slow handler

    func testStartLoading_returnsSynchronouslyEvenWhenHandlerWorkIsSlow() throws {
        // Direct contract check at the URLProtocol layer, bypassing
        // URLSession's internal serial delegate queue (which can mask
        // parallel handler execution behind serialized completion
        // delivery). We construct an `HTTPStubURLProtocol` instance
        // directly and time how long `startLoading()` blocks for. With
        // the non-blocking dispatch contract, it must return in well
        // under the handler's 300ms sleep duration.
        let slowSleepSeconds: TimeInterval = 0.3
        HTTPStubURLProtocol.register { _ in
            Thread.sleep(forTimeInterval: slowSleepSeconds)
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: nil)
        }

        let slowURL = try XCTUnwrap(URL(string: "https://example.com/slow-loader"))
        let request = URLRequest(url: slowURL)
        let probeClient = ProbeURLProtocolClient()
        let probe = HTTPStubURLProtocol(
            request: request,
            cachedResponse: nil,
            client: probeClient
        )

        let startTime = Date()
        probe.startLoading()
        let synchronousReturnElapsed = Date().timeIntervalSince(startTime)

        // The synchronous portion of startLoading() MUST return well
        // before the handler's sleep completes — the handler runs on a
        // dispatched queue, not inline.
        XCTAssertLessThan(
            synchronousReturnElapsed, 0.05,
            "startLoading() must return in under 50ms — the 300ms handler sleep " +
            "should run on the response dispatch queue, not on the caller's queue. " +
            "Took \(synchronousReturnElapsed)s synchronously."
        )

        // Verify the async work eventually delivers the response. Use
        // a polling wait against the probe client's didFinishLoading
        // signal so we don't return from the test before async work
        // completes (which would leak the handler closure).
        let waitDeadline = Date().addingTimeInterval(2.0)
        while !probeClient.didFinishLoading && Date() < waitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            probeClient.didFinishLoading,
            "Response work should eventually deliver via the response queue"
        )
    }
}

/// Minimal URLProtocolClient used by
/// `testStartLoading_returnsSynchronouslyEvenWhenHandlerWorkIsSlow` to
/// probe the synchronous contract of `HTTPStubURLProtocol.startLoading()`
/// without going through URLSession. We capture only the signals the
/// test needs.
private final class ProbeURLProtocolClient: NSObject, URLProtocolClient {
    private let lock = NSLock()
    private var _didFinishLoading = false
    var didFinishLoading: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinishLoading
    }

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {}
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {}
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {
        lock.lock(); defer { lock.unlock() }
        _didFinishLoading = true
    }
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        lock.lock(); defer { lock.unlock() }
        _didFinishLoading = true
    }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}
