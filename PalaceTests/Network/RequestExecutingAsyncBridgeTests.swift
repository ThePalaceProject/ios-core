//
//  RequestExecutingAsyncBridgeTests.swift
//  The Palace Project
//

import XCTest
@testable import Palace

/// Pins the property that makes `TPPRequestExecuting.execute` an architectural
/// fix rather than a style preference: a caller gets its result back on its own
/// actor, whatever thread the request was completed on.
///
/// The callback requirements this replaced could not offer that. A completion
/// typed `(NYPLResult<Data>) -> Void` carries no isolation, so the executor's
/// background delivery reached a closure the compiler believed was main-actor
/// isolated — the PP-5299 crash class. An `await` resumes on the awaiting
/// actor, so the same call is correct by construction.
///
/// The doubles below resume their continuation from a background queue
/// deliberately. That is the closest a double can now come to the old hazard,
/// and the point is that it is no longer hazardous: the caller still continues
/// on the main actor.
@MainActor
final class RequestExecutingAsyncBridgeTests: XCTestCase {

    /// Resumes from a background queue and records which thread it resumed on,
    /// so the main assertion cannot pass vacuously against a double that
    /// happened to resume on main.
    private final class OffMainExecutor: TPPRequestExecuting, @unchecked Sendable {
        var requestTimeout: TimeInterval { 30 }
        static var defaultRequestTimeout: TimeInterval { 30 }

        private let payload: Data
        private let lock = NSLock()
        private var _resumedOnMain: Bool?
        var resumedOnMain: Bool? { lock.withLock { _resumedOnMain } }

        init(payload: Data) { self.payload = payload }

        func execute(_ req: URLRequest,
                     enableTokenRefresh: Bool,
                     accountId: String?) async -> NYPLResult<Data> {
            let payload = self.payload
            return await withCheckedContinuation { continuation in
                DispatchQueue(label: "off-main-completion").async { [weak self] in
                    self?.lock.withLock { self?._resumedOnMain = Thread.isMainThread }
                    continuation.resume(returning: .success(payload, nil))
                }
            }
        }
    }

    private func makeRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://example.org/resource")!)
    }

    // MARK: - The guarantee

    func testExecute_whenCompletedOffMain_returnsToTheMainActorCaller() async {
        let executor = OffMainExecutor(payload: Data("body".utf8))

        let result = await executor.execute(makeRequest(),
                                            enableTokenRefresh: false,
                                            accountId: nil)

        // Runs after the await, in a @MainActor context. The language puts it
        // here — not a hop anyone remembered to write.
        XCTAssertTrue(
            Thread.isMainThread,
            "await returned the caller off the main actor. If that is now "
            + "intended, every main-actor caller migrated to execute() needs "
            + "its own hop again and this surface stops being a fix (PP-5301)."
        )

        // Premise control: without this the assertion above would pass just as
        // happily against a double that resumed on main all along.
        XCTAssertEqual(executor.resumedOnMain, false,
                       "the double resumed on main, so this test proves nothing")

        switch result {
        case let .success(data, _):
            XCTAssertEqual(data, Data("body".utf8))
        case let .failure(error, _):
            XCTFail("expected success, got \(error)")
        }
    }

    /// The failure arm has to carry both parts: sign-in reads problem documents
    /// off error responses, which a throwing signature would have discarded.
    /// This is why `execute` returns `NYPLResult` instead of `throws`.
    func testExecute_failure_preservesBothErrorAndResponse() async {
        final class FailingExecutor: TPPRequestExecuting, @unchecked Sendable {
            var requestTimeout: TimeInterval { 30 }
            static var defaultRequestTimeout: TimeInterval { 30 }
            func execute(_ req: URLRequest,
                         enableTokenRefresh: Bool,
                         accountId: String?) async -> NYPLResult<Data> {
                let response = HTTPURLResponse(url: req.url!, statusCode: 401,
                                               httpVersion: nil, headerFields: nil)
                return await withCheckedContinuation { continuation in
                    DispatchQueue(label: "off-main-failure").async {
                        continuation.resume(
                            returning: .failure(NSError(domain: "test", code: 401), response))
                    }
                }
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
                           "the response must survive — sign-in reads problem "
                           + "documents off it")
        }
    }

    /// The convenience overload must reach the same implementation with a nil
    /// account, which is what "the currently selected library" means.
    func testExecute_convenienceOverload_defaultsToTheCurrentAccount() async {
        final class AccountRecordingExecutor: TPPRequestExecuting, @unchecked Sendable {
            var requestTimeout: TimeInterval { 30 }
            static var defaultRequestTimeout: TimeInterval { 30 }
            private let lock = NSLock()
            private var _sawAccountId: String??
            var sawAccountId: String?? { lock.withLock { _sawAccountId } }
            func execute(_ req: URLRequest,
                         enableTokenRefresh: Bool,
                         accountId: String?) async -> NYPLResult<Data> {
                lock.withLock { _sawAccountId = .some(accountId) }
                return .success(Data(), nil)
            }
        }

        let executor = AccountRecordingExecutor()
        _ = await executor.execute(makeRequest(), enableTokenRefresh: false)
        XCTAssertEqual(executor.sawAccountId, .some(nil),
                       "the convenience overload must pass a nil accountId through")
    }
}
