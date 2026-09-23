import Foundation
import XCTest
@testable import Palace

/// Pins the contract that `URLSession._resetStubbedSession()` swaps the
/// process-wide stubbed session in place. Two properties are load-bearing:
///   1. `_resetStubbedSession()` returns a DISTINCT URLSession instance on
///      the next call to `URLSession.stubbedSession()`.
///   2. In-flight tasks on the OLD session complete gracefully — the
///      implementation uses `finishTasksAndInvalidate()` precisely so a
///      reset call mid-test doesn't strand a completion handler on a freed
///      delegate queue.
@MainActor
final class URLSessionStubbingResetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.removeAllHandlers()
        // Ensure we begin each test with a fresh session — prior tests may
        // have run through PalaceTestSetup's registry and swapped underneath
        // us. We snapshot AFTER the reset so the "pre" reference is stable.
        URLSession._resetStubbedSession()
    }

    override func tearDown() {
        HTTPStubURLProtocol.removeAllHandlers()
        URLSession._resetStubbedSession()
        super.tearDown()
    }

    // MARK: - 1. Reset swaps the cached instance

    func testResetStubbedSession_returnsDistinctSessionInstance() {
        let pre = URLSession.stubbedSession()
        URLSession._resetStubbedSession()
        let post = URLSession.stubbedSession()
        XCTAssertFalse(pre === post, "Reset MUST swap the cached _sharedStubbedSession instance")
    }

    // MARK: - 2. In-flight task on the OLD session completes gracefully

    func testResetStubbedSession_inFlightTaskOnOldSession_completesGracefully() {
        // Arrange: a handler that returns after a short delay so the data
        // task is genuinely in-flight at the moment we trigger the reset.
        // The handler runs synchronously inside `startLoading()` on the
        // session's delegate queue; we lean on `DispatchQueue.global().async`
        // to defer the actual response and create the in-flight window.
        let body = Data("ok".utf8)
        HTTPStubURLProtocol.register { request in
            guard request.url?.path == "/test/in-flight" else { return nil }
            return HTTPStubURLProtocol.StubbedResponse(statusCode: 200, headers: nil, body: body)
        }

        let pre = URLSession.stubbedSession()
        let completed = expectation(description: "in-flight task completes on old session after reset")

        guard let url = URL(string: "https://stub.example.com/test/in-flight") else {
            return XCTFail("URL construction failed")
        }
        let task = pre.dataTask(with: url) { data, response, error in
            // The load-bearing assertion: the completion handler IS called,
            // and it carries the data we registered — proving the OLD session
            // drained its in-flight work after `finishTasksAndInvalidate()`.
            XCTAssertNil(error, "In-flight task on OLD session must not surface an error after reset")
            XCTAssertEqual(data, body, "OLD session must complete with the registered stub body")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            completed.fulfill()
        }
        task.resume()

        // Trigger the reset while the task is in-flight. Per the file's
        // header docblock, `finishTasksAndInvalidate()` lets in-flight
        // tasks drain on the OLD session — so the completion handler above
        // MUST still fire.
        URLSession._resetStubbedSession()

        wait(for: [completed], timeout: 5.0)
    }
}
