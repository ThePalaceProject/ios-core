//
//  StreamingReaderViewControllerScrollRestoreTests.swift
//  PalaceTests
//
//  PP-4161 scroll-restore retry-loop tests for
//  `StreamingReaderViewController`. Drives the `handleDidFinish` /
//  `restoreScroll(to:attempt:)` path with a recording `ScriptEvaluating`
//  stub so we can assert:
//    1. didFinish with a saved scroll emits a `window.scrollTo(0, y)` JS call.
//    2. when JS reports actual ≈ target, we do not retry.
//    3. when JS keeps reporting a mismatch, we retry up to the cap.
//    4. didFinish with no saved scroll does not emit any JS.
//
//  These tests target the layout-race bug Module D's 3rd recording
//  flagged: setContentOffset at didFinish on the BiblioBoard fulfill URL
//  gets clobbered by subsequent JS reflows, so we replaced the
//  UIScrollView-based restore with a JS-based retry loop driven by
//  `window.scrollTo` + `window.scrollY` polling.
//

import CoreGraphics
import XCTest
@testable import Palace

@MainActor
final class StreamingReaderViewControllerScrollRestoreTests: XCTestCase {

    // MARK: - Recording stub for ScriptEvaluating

    private final class RecordingScriptEvaluator: ScriptEvaluating {
        struct Call {
            let javaScript: String
            let completion: ((Any?, Error?) -> Void)?
        }
        private(set) var calls: [Call] = []

        /// Pre-seeded results queue (FIFO). When `evaluate` is called the
        /// next result is popped and invoked synchronously on the
        /// completion handler. If the queue is empty, completion is not
        /// invoked (mimics a hung WKWebView call).
        var resultQueue: [Any?] = []

        func evaluate(
            _ javaScript: String,
            completion: ((Any?, Error?) -> Void)?
        ) {
            calls.append(Call(javaScript: javaScript, completion: completion))
            guard !resultQueue.isEmpty else { return }
            let next = resultQueue.removeFirst()
            completion?(next, nil)
        }
    }

    // MARK: - Helpers

    private func makeBook(id: String = "book-scroll-restore") -> TPPBook {
        TPPBookMocker.mockBook(identifier: id, title: "Scroll Restore Title")
    }

    /// Builds a real `StreamingReaderViewModel` configured with the
    /// FakeStreamingReaderProgressStore + a connected FakeReachability
    /// so the resulting state is `.ready(url, restoredScroll: nil)`.
    /// Tests then construct `StreamingReaderViewController(viewModel:)`
    /// directly so the test body literally instantiates the SUT (per the
    /// check-test-name-vs-body rule).
    private func makeViewModel() -> StreamingReaderViewModel {
        StreamingReaderViewModel(
            book: makeBook(),
            store: FakeStreamingReaderProgressStore(),
            reachability: FakeReachability(connected: true)
        )
    }

    /// Applies the test-seam configuration to a fresh
    /// `StreamingReaderViewController`. Caller is responsible for
    /// constructing the VC and threading it through `viewDidLoad`.
    private func configure(
        _ vc: StreamingReaderViewController,
        savedScroll: CGFloat?,
        evaluator: RecordingScriptEvaluator,
        maxAttempts: Int = 4,
        tolerance: CGFloat = 8.0
    ) {
        // Inject the recording evaluator BEFORE viewDidLoad so the
        // production `if scriptEvaluator == nil` guard leaves our stub
        // in place rather than defaulting to the real WKWebView.
        vc.setScriptEvaluator(evaluator)
        vc.scrollRestoreMaxAttempts = maxAttempts
        vc.scrollRestoreToleranceY = tolerance
        // Run retries synchronously so the test doesn't sleep.
        vc.scrollRestoreRetryDelayNanos = 0
        vc.loadViewIfNeeded()
        vc.setPendingRestoredScroll(savedScroll)
    }

    /// `restoreScroll` schedules retries via `Task { @MainActor in ... }`
    /// — even with a 0-nanosecond sleep these hop through the main
    /// runloop, so the test has to spin briefly between assertions to
    /// let the queued retry Tasks land.
    private func awaitMainTasks(_ iterations: Int = 10) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    // MARK: - Test 1: didFinish with saved scroll emits window.scrollTo

    func testStreamingReaderViewController_didFinish_withSavedScroll_invokesScrollToInJS() async {
        let evaluator = RecordingScriptEvaluator()
        // Pre-seed a "page settled" response so the loop terminates
        // after the first eval and we can assert on the JS string
        // without a retry firing.
        evaluator.resultQueue = [["actual": 565 as Any, "ready": "complete" as Any]]
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 565, evaluator: evaluator)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks()

        XCTAssertEqual(evaluator.calls.count, 1,
            "Expected exactly one JS evaluation for the first restore attempt")
        let js = evaluator.calls[0].javaScript
        XCTAssertTrue(js.contains("window.scrollTo(0, 565)"),
            "JS must include the literal window.scrollTo(0, 565) call. Got: \(js)")
        XCTAssertTrue(js.contains("window.scrollY"),
            "JS must read window.scrollY for verification. Got: \(js)")
    }

    // MARK: - Test 2: actual matches target → no retry

    func testStreamingReaderViewController_didFinish_whenJSReportsActualMatchesTarget_doesNotRetry() async {
        let evaluator = RecordingScriptEvaluator()
        evaluator.resultQueue = [
            ["actual": 565 as Any, "ready": "complete" as Any],
            // Extra results queued in case a stray retry fires —
            // we want the assertion below to catch that, not have it
            // silently hang in the stub.
            ["actual": 565 as Any, "ready": "complete" as Any]
        ]
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 565, evaluator: evaluator, maxAttempts: 4, tolerance: 8.0)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks(20)

        XCTAssertEqual(evaluator.calls.count, 1,
            "When the page reports actual==target the retry loop must terminate immediately")
    }

    // MARK: - Test 3: persistent mismatch retries up to max

    func testStreamingReaderViewController_didFinish_whenJSReportsActualMismatch_retriesUpToMax() async {
        let evaluator = RecordingScriptEvaluator()
        let maxAttempts = 4
        // Always report y=0 — pretend the BiblioBoard reflow keeps
        // resetting the scroll. We want exactly `maxAttempts` evals.
        for _ in 0..<(maxAttempts + 2) {
            evaluator.resultQueue.append(["actual": 0 as Any, "ready": "complete" as Any])
        }
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 565, evaluator: evaluator, maxAttempts: maxAttempts, tolerance: 8.0)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks(50)

        XCTAssertEqual(evaluator.calls.count, maxAttempts,
            "Expected exactly maxAttempts (\(maxAttempts)) JS evaluations, got \(evaluator.calls.count)")
        // Every call should be a window.scrollTo with the same target.
        for (i, call) in evaluator.calls.enumerated() {
            XCTAssertTrue(call.javaScript.contains("window.scrollTo(0, 565)"),
                "Retry attempt #\(i) JS must contain window.scrollTo(0, 565)")
        }
    }

    // MARK: - Test 4: no saved scroll → no JS

    func testStreamingReaderViewController_didFinish_withNoSavedScroll_doesNotInvokeScrollTo() async {
        let evaluator = RecordingScriptEvaluator()
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: nil, evaluator: evaluator)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks()

        XCTAssertTrue(evaluator.calls.isEmpty,
            "No saved scroll → no JS eval. Got \(evaluator.calls.count) evals")
    }

    // MARK: - Bonus: saved scroll of 0 is treated as "no restore"

    func testStreamingReaderViewController_didFinish_withSavedScrollZero_doesNotInvokeScrollTo() async {
        // Persisting y=0 would mean "user was at top" — re-applying that
        // is redundant (web view starts at 0). Production guards
        // `restored > 0` to avoid wasting JS round-trips on the top of
        // the page.
        let evaluator = RecordingScriptEvaluator()
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 0, evaluator: evaluator)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks()

        XCTAssertTrue(evaluator.calls.isEmpty,
            "Saved scroll == 0 → no JS eval. Got \(evaluator.calls.count) evals")
    }

    // MARK: - Bonus: tolerance window short-circuits the retry loop

    func testStreamingReaderViewController_didFinish_whenActualWithinTolerance_doesNotRetry() async {
        // Target 565, page reports 560 → 5px off, well under the 8px
        // tolerance. The loop must NOT retry.
        let evaluator = RecordingScriptEvaluator()
        evaluator.resultQueue = [
            ["actual": 560 as Any, "ready": "complete" as Any]
        ]
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 565, evaluator: evaluator, maxAttempts: 4, tolerance: 8.0)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks(20)

        XCTAssertEqual(evaluator.calls.count, 1,
            "When |actual - target| < tolerance the retry loop must terminate")
    }

    // MARK: - Bonus: malformed JS result triggers retry, then bails at cap

    func testStreamingReaderViewController_didFinish_whenJSResultMalformed_retriesUpToMax() async {
        // Simulate a WKWebView returning the wrong shape (e.g. a string
        // when we expected a dictionary). The retry loop should keep
        // trying so a transient WKWebView quirk doesn't strand the user
        // at y=0, then bail at the cap.
        let evaluator = RecordingScriptEvaluator()
        let maxAttempts = 3
        for _ in 0..<(maxAttempts + 2) {
            evaluator.resultQueue.append("not-a-dictionary")
        }
        let vc = StreamingReaderViewController(viewModel: makeViewModel())
        configure(vc, savedScroll: 565, evaluator: evaluator, maxAttempts: maxAttempts, tolerance: 8.0)

        vc.handleDidFinish(currentScrollY: 0)
        await awaitMainTasks(50)

        XCTAssertEqual(evaluator.calls.count, maxAttempts,
            "Malformed JS result must retry up to maxAttempts, then bail")
    }

    // MARK: - parseActualY decoder

    func testStreamingReaderViewController_parseActualY_returnsValueFromNSNumber() {
        let result: Any = ["actual": NSNumber(value: 565.0), "ready": "complete"]
        XCTAssertEqual(StreamingReaderViewController.parseActualY(from: result), 565.0)
    }

    func testStreamingReaderViewController_parseActualY_returnsValueFromInt() {
        let result: Any = ["actual": 565, "ready": "complete"]
        XCTAssertEqual(StreamingReaderViewController.parseActualY(from: result), 565.0)
    }

    func testStreamingReaderViewController_parseActualY_returnsValueFromDouble() {
        let result: Any = ["actual": 565.5 as Double, "ready": "complete"]
        XCTAssertEqual(StreamingReaderViewController.parseActualY(from: result), 565.5)
    }

    func testStreamingReaderViewController_parseActualY_returnsNilOnNonDictionary() {
        XCTAssertNil(StreamingReaderViewController.parseActualY(from: "not-a-dictionary"))
        XCTAssertNil(StreamingReaderViewController.parseActualY(from: nil))
    }

    func testStreamingReaderViewController_parseActualY_returnsNilWhenActualMissing() {
        let result: Any = ["ready": "complete"]
        XCTAssertNil(StreamingReaderViewController.parseActualY(from: result))
    }
}
