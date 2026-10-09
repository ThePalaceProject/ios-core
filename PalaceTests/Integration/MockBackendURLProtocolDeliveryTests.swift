//
//  MockBackendURLProtocolDeliveryTests.swift
//  PalaceTests
//
//  The URL loading system expects a URLProtocol to call its client on the
//  thread that called startLoading. These tests pin that the mock backend does
//  so, which keeps a busy main thread from stalling a stubbed request.
//

import XCTest
@testable import Palace

final class MockBackendURLProtocolDeliveryTests: XCTestCase {

    private static let base = "https://delivery.mock-backend.test"

    override func setUp() {
        super.setUp()
        MockBackendURLProtocol.activeScenario = MockScenario(
            id: "delivery",
            displayName: "Delivery",
            description: "Routes for client-thread delivery tests",
            routes: [
                MockRoute(pathPattern: "^https://delivery\\.mock-backend\\.test/immediate$",
                          fixtureName: "auth_document"),
                MockRoute(pathPattern: "^https://delivery\\.mock-backend\\.test/delayed$",
                          fixtureName: "auth_document", delayMs: 50),
                MockRoute(pathPattern: "^https://delivery\\.mock-backend\\.test/missing$",
                          fixtureName: "no_such_fixture_for_delivery_tests")
            ]
        )
    }

    override func tearDown() {
        MockBackendURLProtocol.activeScenario = nil
        super.tearDown()
    }

    // MARK: - Through URLSession, with the main thread occupied

    /// A request served while main is blocked must still complete; CI runners
    /// with a saturated main thread turned the old main-queue finish into -1001.
    func testImmediateRoute_WhileMainThreadIsBlocked_CompletesWithFixture() throws {
        let outcome = try fetchWhileBlockingMain(path: "immediate")

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.statusCode, 200)
        XCTAssertEqual(outcome.data, EmbeddedFixtures.data(for: "auth_document"))
    }

    /// The delayed path must also finish without the main thread.
    func testDelayedRoute_WhileMainThreadIsBlocked_CompletesWithFixture() throws {
        let outcome = try fetchWhileBlockingMain(path: "delayed")

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.statusCode, 200)
        XCTAssertEqual(outcome.data, EmbeddedFixtures.data(for: "auth_document"))
    }

    // MARK: - Direct client, recording thread and order

    /// Response and data arrive inside startLoading and finish on a later run loop
    /// pass, all on the startLoading thread; the responder relies on that pass.
    func testImmediateRoute_CallsClientOnStartLoadingThread_FinishAfterReturn() {
        let run = startLoadingOnDedicatedThread(path: "immediate")

        XCTAssertEqual(run.events.map(\.name), ["response", "data", "startLoadingReturned", "finish"])
        XCTAssertTrue(run.events.allSatisfy { $0.thread === run.loadingThread },
                      "Every client call must happen on the thread that called startLoading")
    }

    /// The delayed route waits off-thread but still delivers on the startLoading thread.
    func testDelayedRoute_CallsClientOnStartLoadingThread_InOrder() {
        let run = startLoadingOnDedicatedThread(path: "delayed")

        XCTAssertEqual(run.events.map(\.name), ["startLoadingReturned", "response", "data", "finish"])
        XCTAssertTrue(run.events.allSatisfy { $0.thread === run.loadingThread },
                      "Every client call must happen on the thread that called startLoading")
    }

    /// A missing fixture fails once, on the startLoading thread, with no response.
    func testMissingFixture_FailsOnStartLoadingThread() {
        let run = startLoadingOnDedicatedThread(path: "missing")

        XCTAssertEqual(run.events.map(\.name), ["fail", "startLoadingReturned"])
        XCTAssertTrue(run.events.allSatisfy { $0.thread === run.loadingThread })
    }

    // MARK: - Helpers

    private struct FetchOutcome {
        let data: Data?
        let statusCode: Int?
        let error: Error?
    }

    private func fetchWhileBlockingMain(path: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws -> FetchOutcome {
        XCTAssertTrue(Thread.isMainThread, "The test must occupy the main thread", file: file, line: line)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockBackendURLProtocol.self]
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let box = LockedBox<FetchOutcome>()
        let done = DispatchSemaphore(value: 0)
        let url = try XCTUnwrap(URL(string: "\(Self.base)/\(path)"))
        session.dataTask(with: url) { data, response, error in
            box.set(FetchOutcome(data: data,
                                 statusCode: (response as? HTTPURLResponse)?.statusCode,
                                 error: error))
            done.signal()
        }.resume()

        // Blocks main for the whole request; nothing can be serviced on it.
        let waited = done.wait(timeout: .now() + 5)
        XCTAssertEqual(waited, .success,
                       "Stubbed request did not complete while the main thread was blocked",
                       file: file, line: line)
        return try XCTUnwrap(box.get(), file: file, line: line)
    }

    private struct LoadingRun {
        let events: [SpyClient.Event]
        let loadingThread: Thread?
    }

    private func startLoadingOnDedicatedThread(path: String) -> LoadingRun {
        let finished = expectation(description: "client reached a terminal call")
        let returned = expectation(description: "startLoading returned")
        let client = SpyClient(onTerminal: { finished.fulfill() })
        let request = URLRequest(url: URL(string: "\(Self.base)/\(path)")!)
        let loader = MockBackendURLProtocol(request: request, cachedResponse: nil, client: client)

        let thread = RunLoopThread {
            loader.startLoading()
            client.mark("startLoadingReturned")
            returned.fulfill()
        }
        thread.start()
        wait(for: [finished, returned], timeout: 5)
        // Let any late, unexpected client call land before reading the log.
        Thread.sleep(forTimeInterval: 0.1)
        thread.cancel()

        return LoadingRun(events: client.events, loadingThread: thread)
    }
}

// MARK: - Test doubles

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
}

/// A thread that runs its run loop, as the URL loading system's client thread does.
private final class RunLoopThread: Thread, @unchecked Sendable {
    private let work: () -> Void

    init(work: @escaping () -> Void) {
        self.work = work
        super.init()
    }

    override func main() {
        let runLoop = RunLoop.current
        runLoop.add(Port(), forMode: .default)
        work()
        while !isCancelled {
            _ = runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

/// Records each client callback with the thread it arrived on.
private final class SpyClient: NSObject, URLProtocolClient, @unchecked Sendable {
    struct Event {
        let name: String
        let thread: Thread
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private let onTerminal: () -> Void

    init(onTerminal: @escaping () -> Void) {
        self.onTerminal = onTerminal
    }

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Records a test-side marker in the same sequence as client callbacks.
    func mark(_ name: String) {
        record(name)
    }

    private func record(_ name: String) {
        lock.lock()
        recorded.append(Event(name: name, thread: Thread.current))
        lock.unlock()
    }

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {
        record("redirect")
    }

    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {
        record("cached")
    }

    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse,
                     cacheStoragePolicy policy: URLCache.StoragePolicy) {
        record("response")
    }

    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {
        record("data")
    }

    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {
        record("finish")
        onTerminal()
    }

    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        record("fail")
        onTerminal()
    }

    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {
        record("challenge")
    }

    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {
        record("cancelChallenge")
    }
}
