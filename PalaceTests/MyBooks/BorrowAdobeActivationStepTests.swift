//
//  BorrowAdobeActivationStepTests.swift
//  PalaceTests
//
//  Critical-path coverage for the Adobe activation step of a borrow (PP-5025).
//
//  This step is small but it is where three separate contracts now live, and
//  review found all three defeatable with the suite green before these tests
//  existed:
//
//    1. It opts into the licensor grace period. `ensureDeviceActivated`
//       defaults to no wait, so deleting the budget here makes the PP-5025 fix
//       inert in the only place it is active.
//    2. It raises the processing spinner BEFORE activation. Moving that after
//       the wait removes the file's whole reason to exist — `BookCellModel`
//       sets no `isLoading`, so the Get button would sit unchanged and
//       tappable for the duration.
//    3. It clears the spinner if activation throws. Deleting that strands the
//       spinner for the process lifetime — CLAUDE.md names this exact shape
//       ("removing `registry.setProcessing(false)` mid-cleanup would leak
//       forever") as a contract-test case.
//
//  Note there is deliberately no `#if FEATURE_DRM_CONNECTOR` here. PalaceTests
//  does not define that flag, so a conditional in TEST source takes the `#else`
//  and silently skips — which is why DRMAdversarialTests' Adobe coverage is
//  dead. The symbols resolve regardless because the Palace module under test
//  was built with the flag.
//

import XCTest
@testable import Palace

final class BorrowAdobeActivationStepTests: XCTestCase {

    /// Records the spinner transitions and the activation budget in one
    /// ordered log, so ORDER is assertable and not just the final state.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _budgets: [TimeInterval] = []

        func note(_ event: String) { lock.withLock { _events.append(event) } }
        func noteBudget(_ b: TimeInterval) { lock.withLock { _budgets.append(b) } }
        var events: [String] { lock.withLock { _events } }
        var budgets: [TimeInterval] { lock.withLock { _budgets } }
    }

    private struct ActivationFailed: Error {}

    // MARK: - It opts into the grace period

    func test_run_activatesWithTheBorrowGracePeriod() async throws {
        let recorder = Recorder()

        try await BorrowAdobeActivationStep.run(
            setProcessing: { _ in },
            activate: { budget in recorder.noteBudget(budget) }
        )

        XCTAssertEqual(recorder.budgets.count, 1)
        XCTAssertEqual(recorder.budgets.first, AdobeDRMService.defaultLicensorGracePeriod,
                       "borrow must opt into the licensor grace period — at 0 the PP-5025 fix is inert in the only place it is active")
    }

    // MARK: - Spinner ordering

    func test_run_raisesTheSpinnerBeforeActivating() async throws {
        let recorder = Recorder()

        try await BorrowAdobeActivationStep.run(
            setProcessing: { recorder.note($0 ? "processing:true" : "processing:false") },
            activate: { _ in recorder.note("activate") }
        )

        XCTAssertEqual(recorder.events, ["processing:true", "activate"],
                       "the spinner must be up for the duration of the wait, not raised after it")
    }

    func test_run_onSuccess_leavesTheSpinnerUpForTheCaller() async throws {
        let recorder = Recorder()

        try await BorrowAdobeActivationStep.run(
            setProcessing: { recorder.note($0 ? "processing:true" : "processing:false") },
            activate: { _ in }
        )

        XCTAssertFalse(recorder.events.contains("processing:false"),
                       "on success the borrow continues and owns the spinner — clearing it here would flicker the cell")
    }

    // MARK: - Clear on throw

    func test_run_whenActivationThrows_clearsTheSpinnerAndRethrows() async {
        let recorder = Recorder()

        do {
            try await BorrowAdobeActivationStep.run(
                setProcessing: { recorder.note($0 ? "processing:true" : "processing:false") },
                activate: { _ in throw ActivationFailed() }
            )
            XCTFail("the activation error must reach the caller")
        } catch {
            XCTAssertTrue(error is ActivationFailed, "the original error must propagate unchanged, got \(error)")
        }

        XCTAssertEqual(recorder.events, ["processing:true", "processing:false"],
                       "a failed activation must clear the spinner — otherwise the cell spins forever with no clearer")
    }
}
