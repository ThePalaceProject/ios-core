//
//  ReturnReducerContractTests.swift
//  PalaceTests
//
//  E2 (WS7) coverage for the pure `ReturnReducer` extracted from
//  `BookReturnService`. Direct `Equatable` assertions on `startRoute`,
//  `classifyError`, and `cleanupEffects` kill mutants (flipped guards, dropped
//  ladder arms, swapped teardown order). The `ContractSnapshot` layer
//  interprets `cleanupEffects` into a `CallLog` using the SAME collaborator
//  labels `BookReturnServiceContractTests` records, so the emitted teardown is
//  shape-equal to the cleanup tail of the E1 service snapshots (the
//  behavior-preservation proof Contract E requires).
//

import XCTest
@testable import Palace

final class ReturnReducerContractTests: XCTestCase {

    // MARK: - startRoute

    func test_startRoute_noRevokeURL_cleansUpWithoutNetwork() {
        XCTAssertEqual(ReturnReducer.startRoute(hasRevokeURL: false), .cleanupWithoutNetwork)
    }

    func test_startRoute_hasRevokeURL_revokesOverNetwork() {
        XCTAssertEqual(ReturnReducer.startRoute(hasRevokeURL: true), .revokeOverNetwork)
    }

    // MARK: - classifyError

    private func facts(
        isOPDSParseFailure: Bool = false,
        isNoActiveLoan: Bool = false,
        isLoanTermLimitReached: Bool = false,
        isAuthError: Bool = false,
        isOffline: Bool = false,
        hasOfflineEnqueuer: Bool = false
    ) -> ReturnReducer.ErrorFacts {
        .init(isOPDSParseFailure: isOPDSParseFailure, isNoActiveLoan: isNoActiveLoan,
              isLoanTermLimitReached: isLoanTermLimitReached, isAuthError: isAuthError,
              isOffline: isOffline, hasOfflineEnqueuer: hasOfflineEnqueuer)
    }

    func test_classify_opdsParseFailure_treatsAsSuccess() {
        XCTAssertEqual(ReturnReducer.classifyError(facts(isOPDSParseFailure: true)), .treatAsSuccessCleanup)
    }

    func test_classify_noActiveLoan_treatsAsSuccess() {
        XCTAssertEqual(ReturnReducer.classifyError(facts(isNoActiveLoan: true)), .treatAsSuccessCleanup)
    }

    func test_classify_loanTermLimit_treatsAsSuccess() {
        XCTAssertEqual(ReturnReducer.classifyError(facts(isLoanTermLimitReached: true)), .treatAsSuccessCleanup)
    }

    func test_classify_authError_reauths() {
        XCTAssertEqual(ReturnReducer.classifyError(facts(isAuthError: true)), .reauthAndRetry)
    }

    func test_classify_offlineWithEnqueuer_enqueues() {
        XCTAssertEqual(ReturnReducer.classifyError(facts(isOffline: true, hasOfflineEnqueuer: true)), .enqueueOffline)
    }

    func test_classify_offlineWithoutEnqueuer_fallsToGenericAlert() {
        // Offline but no enqueuer wired → NOT enqueued; the patron sees the alert.
        XCTAssertEqual(ReturnReducer.classifyError(facts(isOffline: true, hasOfflineEnqueuer: false)), .genericFailureAlert)
    }

    func test_classify_unknown_genericAlert() {
        XCTAssertEqual(ReturnReducer.classifyError(facts()), .genericFailureAlert)
    }

    func test_classify_treatAsSuccess_winsOverAuthError() {
        // Ladder order: a loan-gone signal short-circuits before the auth arm.
        XCTAssertEqual(
            ReturnReducer.classifyError(facts(isNoActiveLoan: true, isAuthError: true)),
            .treatAsSuccessCleanup)
    }

    func test_classify_authError_winsOverOffline() {
        XCTAssertEqual(
            ReturnReducer.classifyError(facts(isAuthError: true, isOffline: true, hasOfflineEnqueuer: true)),
            .reauthAndRetry)
    }

    // MARK: - cleanupEffects

    func test_cleanup_downloaded_treatAsSuccess_order() {
        XCTAssertEqual(
            ReturnReducer.cleanupEffects(downloaded: true, useUpdateAndRemove: false),
            [.deleteLocalContent, .purgeAudiobookCaches, .setStateUnregistered, .removeBook, .announceReturnSucceeded])
    }

    func test_cleanup_notDownloaded_skipsLocalTeardown() {
        XCTAssertEqual(
            ReturnReducer.cleanupEffects(downloaded: false, useUpdateAndRemove: false),
            [.setStateUnregistered, .removeBook, .announceReturnSucceeded])
    }

    func test_cleanup_networkSuccess_usesUpdateAndRemoveThenSetState() {
        // The normal network-revoke success supplies a parsed book →
        // updateAndRemoveBook THEN setState (BookReturnService.swift :364-365).
        XCTAssertEqual(
            ReturnReducer.cleanupEffects(downloaded: true, useUpdateAndRemove: true),
            [.deleteLocalContent, .purgeAudiobookCaches, .updateAndRemoveBook, .setStateUnregistered, .announceReturnSucceeded])
    }

    // MARK: - Shape-equality snapshot (proof vs E1 service snapshot cleanup tail)

    func test_snapshot_cleanup_downloaded_treatAsSuccess() {
        let log = interpretCleanup(downloaded: true, useUpdateAndRemove: false)
        ContractSnapshot.assert(log, named: "cleanup_downloaded_treatAsSuccess")
    }

    func test_snapshot_cleanup_networkSuccess() {
        let log = interpretCleanup(downloaded: true, useUpdateAndRemove: true)
        ContractSnapshot.assert(log, named: "cleanup_networkSuccess_updateAndRemove")
    }

    // MARK: - Helpers

    private static let bookId = "RET-CORE"

    /// Interprets `cleanupEffects` into a CallLog with the identical labels +
    /// arg shape `BookReturnServiceContractTests` records, so the JSON is
    /// shape-equal to the cleanup tail of the service snapshot.
    private func interpretCleanup(downloaded: Bool, useUpdateAndRemove: Bool) -> CallLog {
        let log = CallLog()
        let id = Self.bookId
        for effect in ReturnReducer.cleanupEffects(downloaded: downloaded, useUpdateAndRemove: useUpdateAndRemove) {
            switch effect {
            case .deleteLocalContent:
                log.record("localContent.deleteLocalContent", args: ["account": "nil", "bookId": id])
            case .purgeAudiobookCaches:
                log.record("delegate.purgeAllAudiobookCaches", args: ["force": "true"])
            case .updateAndRemoveBook:
                log.record("registry.updateAndRemoveBook", args: ["bookId": id])
            case .setStateUnregistered:
                log.record("registry.setState", args: ["bookId": id, "state": "unregistered"])
            case .removeBook:
                log.record("registry.removeBook", args: ["bookId": id])
            case .announceReturnSucceeded:
                log.record("announce.returnSucceeded", args: ["bookId": id])
            }
        }
        return log
    }
}
