//
//  TPPDRMAuthorizingMockTimeoutTests.swift
//  PalaceTests
//
//  Proves the deauthorize wait ENDS instead of hanging.
//
//  This test exists because the guard was written three times and the first two
//  could not report.
//
//  1. `_awaitDeauthorizeCalledForTesting` was originally an unbounded
//     `withCheckedContinuation`. When a production change stopped reaching
//     `deauthorize`, it held a run open for ten hours at 0% CPU.
//  2. The first repair raced that continuation against `Task.sleep` inside a
//     `withTaskGroup` — which cannot work, because the group awaits every child
//     before returning and an unresumed `CheckedContinuation` does not observe
//     cancellation. The timeout leg won, the group could not drain, and the call
//     hung exactly as before with its `XCTFail` unreachable.
//  3. The polling rewrite fixed the hang, but this test still could not prove
//     it. It drove the ASSERTING wrapper under `XCTExpectFailure`, and that is
//     order-dependent: `XCTExpectFailure` installs an issue matcher on the
//     current execution context, while the `XCTFail` it is meant to absorb is
//     reached after an `await` that may resume on another thread. Run alone the
//     test passed; in a fifteen-suite run the same code failed with "Expected
//     failure ... but none recorded". A proof with two verdicts is not a proof.
//
//  So the proof now drives `_awaitDeauthorizeCalledOrTimeout`, which RETURNS its
//  verdict rather than reporting it. No expected-failure machinery, no thread
//  affinity, and the assertion is about the value the wait produced.
//
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
