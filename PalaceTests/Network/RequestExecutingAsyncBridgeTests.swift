//
//  RequestExecutingAsyncBridgeTests.swift
//  The Palace Project
//

import XCTest
@testable import Palace

/// Pins the guarantee that `TPPRequestExecuting.execute` exists to provide:
/// a caller gets its result back on its own actor, whatever thread the
/// underlying callback arrived on.
///
/// This is the property that makes the async surface an architectural fix
/// rather than a style preference. The callback forms cannot offer it — a
/// completion typed `(NYPLResult<Data>) -> Void` carries no isolation, so the
/// executor's background delivery reaches a closure the compiler believes is
/// main-actor isolated, which is the PP-5299 crash class. An `await` resumes on
/// the awaiting actor, so the same call is correct by construction.
///
/// The double below delivers off the main thread deliberately, matching
/// production: `TPPNetworkExecutor` builds its sessions with `delegateQueue:
/// nil`, so a real completion never arrives on main.
@MainActor
final class RequestExecutingAsyncBridgeTests: XCTestCase {

    /// Minimal conformer: delivers on a background queue and nothing else.
    /// Deliberately does NOT implement `execute`, so the protocol's bridging
    /// default is what the tests exercise — that default is what every mock in
    /// the suite inherits.
    private final class OffMainExecutor: TPPRequestExecuting, @unchecked Sendable {
        var requestTimeout: TimeInterval { 30 }
        static var defaultRequestTimeout: TimeInterval { 30 }

        let payload: Data
        /// Thread the callback was invoked on, for the premise assertion.
        private(set) var deliveredOnMain: Bool?

        init(payload: Data) { self.payload = payload }

        @discardableResult
        func executeRequest(_ req: URLRequest,
                            enableTokenRefresh: Bool,
                            completion: @escaping (NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
            let payload = self.payload
            DispatchQueue(label: "off-main-delivery").async { [weak self] in
                self?.deliveredOnMain = Thread.isMainThread
                completion(.success(payload, nil))
            }
            return nil
        }
    }

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://example.org/resource")!)
    }

    // MARK: - The guarantee

    func testExecute_whenCallbackArrivesOffMain_resumesTheMainActorCaller() async {
        let executor = OffMainExecutor(payload: Data("body".utf8))

        let result = await executor.execute(makeRequest(),
                                            enableTokenRefresh: false,
                                            accountId: nil)

        // The point of the test. This assertion runs after the await, in a
        // @MainActor context, and the language — not a hop someone remembered —
        // is what puts it here.
        XCTAssertTrue(
            Thread.isMainThread,
            "await returned the caller off the main actor. If that is now "
            + "intended, every main-actor caller migrated to execute() needs "
            + "its own hop again and this surface stops being a fix (PP-5301)."
        )

        // Premise control: the assertion above is only meaningful if delivery
        // really was off-main. Without this the test would pass just as happily
        // against a double that delivered on main all along.
        XCTAssertEqual(executor.deliveredOnMain, false,
                       "the double delivered on main, so this test proves nothing")

        switch result {
        case let .success(data, _):
            XCTAssertEqual(data, Data("body".utf8))
        case let .failure(error, _):
            XCTFail("expected success, got \(error)")
        }
    }

    /// The failure arm has to survive the bridge too: sign-in reads problem
    /// documents off error responses, which a throwing signature would discard.
    func testExecute_failure_preservesBothErrorAndResponse() async {
        final class FailingExecutor: TPPRequestExecuting, @unchecked Sendable {
            var requestTimeout: TimeInterval { 30 }
            static var defaultRequestTimeout: TimeInterval { 30 }
            @discardableResult
            func executeRequest(_ req: URLRequest,
                                enableTokenRefresh: Bool,
                                completion: @escaping (NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
                let response = HTTPURLResponse(url: req.url!, statusCode: 401,
                                               httpVersion: nil, headerFields: nil)
                DispatchQueue(label: "off-main-failure").async {
                    completion(.failure(NSError(domain: "test", code: 401), response))
                }
                return nil
            }
        }

        let result = await FailingExecutor().execute(makeRequest(),
                                                     enableTokenRefresh: false,
                                                     accountId: nil)

        switch result {
        case .success:
            XCTFail("expected failure")
        case let .failure(error, response):
            XCTAssertEqual((error as NSError).code, 401)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401,
                           "the response must survive the bridge — sign-in reads "
                           + "problem documents off it")
        }
    }

    /// Exactly one resumption, even though the double fires its callback twice.
    /// A continuation resumed twice traps, so this would crash rather than fail.
    func testExecute_callbackInvokedTwice_resumesOnce() async {
        final class DoubleFiringExecutor: TPPRequestExecuting, @unchecked Sendable {
            var requestTimeout: TimeInterval { 30 }
            static var defaultRequestTimeout: TimeInterval { 30 }
            @discardableResult
            func executeRequest(_ req: URLRequest,
                                enableTokenRefresh: Bool,
                                completion: @escaping (NYPLResult<Data>) -> Void) -> URLSessionDataTask? {
                DispatchQueue(label: "double-fire").async {
                    completion(.success(Data("first".utf8), nil))
                    completion(.success(Data("second".utf8), nil))
                }
                return nil
            }
        }

        let result = await DoubleFiringExecutor().execute(makeRequest(),
                                                          enableTokenRefresh: false,
                                                          accountId: nil)
        switch result {
        case let .success(data, _):
            XCTAssertEqual(data, Data("first".utf8), "the first result should win")
        case let .failure(error, _):
            XCTFail("expected success, got \(error)")
        }
    }
}
