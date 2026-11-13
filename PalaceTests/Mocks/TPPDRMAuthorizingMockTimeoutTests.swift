//
//  Proves the deauthorize wait ends instead of hanging. An unbounded continuation
//  once held a run open for hours when `deauthorize` stopped being reached, and a
//  task-group timeout cannot cancel an unresumed continuation. An
//  `XCTExpectFailure`-based proof was order-dependent across threads, so this
//  drives `_awaitDeauthorizeCalledOrTimeout`, which returns its verdict.
//  A regression hangs this test rather than the whole suite.
//

import XCTest
@testable import Palace

final class TPPDRMAuthorizingMockTimeoutTests: XCTestCase {

  func test_awaitDeauthorize_whenNeverCalled_reportsTimeoutInsteadOfHanging() async {
    let mock = TPPDRMAuthorizingMock()

    let started = Date()
    let signalled = await mock._awaitDeauthorizeCalledOrTimeout(timeout: 0.5)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertFalse(signalled,
                   "deauthorize was never called, so the wait must report a timeout — a `true` here is how "
                   + "a sign-out path that silently stopped deauthorizing reads as working")
    XCTAssertGreaterThanOrEqual(elapsed, 0.4,
                                "returned before its own deadline — something other than the timeout released it")
    XCTAssertLessThan(elapsed, 5.0,
                      "returned, but far past the 0.5s deadline — the bound is not being honoured")
  }

  func test_awaitDeauthorize_whenAlreadyCalled_returnsImmediately() async {
    // The clean path. A guard exercised only against the failure it detects
    // passes while rejecting every legitimate input — so assert the wait does
    // NOT spend its deadline when deauthorize has already happened.
    let mock = TPPDRMAuthorizingMock()
    mock.deauthorize(withUsername: "u", password: "p",
                     userID: "uid", deviceID: "did") { _, _ in }

    let started = Date()
    let signalled = await mock._awaitDeauthorizeCalledOrTimeout(timeout: 5)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertTrue(signalled)
    XCTAssertLessThan(elapsed, 1.0,
                      "already-called must short-circuit, not wait out the deadline")
  }

  /// The edge the polling loop exists for: `deauthorize` arrives WHILE the wait
  /// is in progress. The unbounded continuation handled this by being resumed;
  /// a poll has to re-read the flag every iteration, and a loop that read it
  /// only once would pass both tests above and fail here.
  func test_awaitDeauthorize_whenCalledMidWait_observesItBeforeTheDeadline() async {
    let mock = TPPDRMAuthorizingMock()

    Task {
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
      mock.deauthorize(withUsername: "u", password: "p",
                       userID: "uid", deviceID: "did") { _, _ in }
    }

    let started = Date()
    let signalled = await mock._awaitDeauthorizeCalledOrTimeout(timeout: 5)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertTrue(signalled,
                  "a deauthorize that lands mid-wait must be observed — the loop has to re-read the flag")
    XCTAssertLessThan(elapsed, 4.0,
                      "observed only at the deadline, which means the loop is not polling")
  }
}
