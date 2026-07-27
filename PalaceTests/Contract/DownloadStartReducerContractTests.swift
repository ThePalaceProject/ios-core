//
//  DownloadStartReducerContractTests.swift
//  PalaceTests
//
//  E2 (WS7) coverage for the pure `DownloadStartReducer` extracted from
//  `DownloadStartDispatcher`. Two complementary layers:
//
//  1. Direct `Equatable` assertions on the emitted plan (`reduceUnregistered`,
//     `routeWithCredentials`, `reduceRegular`) — these kill mutants: a flipped
//     guard, dropped case, or swapped effect order produces an unequal value.
//  2. A `ContractSnapshot` layer that interprets each emitted plan into a
//     `CallLog` using the SAME collaborator labels as
//     `DownloadStartDispatcherContractTests`. The resulting JSON is shape-equal
//     to the E1 dispatcher service snapshot — the behavior-preservation proof
//     Contract E requires (the reducer decides the same ordered sequence the
//     dispatcher used to emit inline).
//

import XCTest
@testable import Palace
import PalaceBookModel

final class DownloadStartReducerContractTests: XCTestCase {

    // MARK: - reduceUnregistered

    func test_reduceUnregistered_openAccessNoBorrow_seeds() {
        let d = DownloadStartReducer.reduceUnregistered(
            .init(hasBorrowLink: false, hasOpenAccess: true, loginRequired: true))
        XCTAssertEqual(d, .seedDownloadNeeded)
    }

    func test_reduceUnregistered_noBorrow_noLogin_seeds() {
        // No borrow link + login not required → downloadable even without an
        // explicit open-access acquisition.
        let d = DownloadStartReducer.reduceUnregistered(
            .init(hasBorrowLink: false, hasOpenAccess: false, loginRequired: false))
        XCTAssertEqual(d, .seedDownloadNeeded)
    }

    func test_reduceUnregistered_borrowLink_staysUnregistered() {
        let d = DownloadStartReducer.reduceUnregistered(
            .init(hasBorrowLink: true, hasOpenAccess: false, loginRequired: true))
        XCTAssertEqual(d, .stayUnregistered)
    }

    func test_reduceUnregistered_noBorrow_loginRequired_noOpenAccess_staysUnregistered() {
        // Guards the `(hasOpenAccess || !loginRequired)` arm: both false ⇒ stay.
        let d = DownloadStartReducer.reduceUnregistered(
            .init(hasBorrowLink: false, hasOpenAccess: false, loginRequired: true))
        XCTAssertEqual(d, .stayUnregistered)
    }

    // MARK: - routeWithCredentials

    func test_route_streamingHTML_noop() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: true, state: .downloadNeeded,
                  isOverdriveAudiobook: false, shouldDeferOverdrive: false))
        XCTAssertEqual(r, .noop)
    }

    func test_route_unregistered_startBorrow() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: false, state: .unregistered,
                  isOverdriveAudiobook: false, shouldDeferOverdrive: false))
        XCTAssertEqual(r, .startBorrow)
    }

    func test_route_holding_startBorrow() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: false, state: .holding,
                  isOverdriveAudiobook: false, shouldDeferOverdrive: false))
        XCTAssertEqual(r, .startBorrow)
    }

    func test_route_overdriveAudiobook_ready_processes() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: false, state: .downloadSuccessful,
                  isOverdriveAudiobook: true, shouldDeferOverdrive: false))
        XCTAssertEqual(r, .processOverdrive)
    }

    func test_route_overdriveAudiobook_deferred_defers() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: false, state: .downloadSuccessful,
                  isOverdriveAudiobook: true, shouldDeferOverdrive: true))
        XCTAssertEqual(r, .deferOverdrive)
    }

    func test_route_regular_fallsThrough() {
        let r = DownloadStartReducer.routeWithCredentials(
            .init(isStreamingHTML: false, state: .downloadSuccessful,
                  isOverdriveAudiobook: false, shouldDeferOverdrive: false))
        XCTAssertEqual(r, .fallThroughToRegular)
    }

    // MARK: - reduceRegular (direct plan assertions)

    func test_regular_expiredWithBorrow_setUnregisteredThenReBorrow() {
        let plan = DownloadStartReducer.reduceRegular(regularInput(isExpired: true, hasBorrowLink: true))
        XCTAssertEqual(plan, [.setStateUnregistered, .startBorrow(attemptDownload: true, withCompletion: false)])
    }

    func test_regular_downloadNeededWithBorrow_setUnregisteredThenAutoBorrow() {
        let plan = DownloadStartReducer.reduceRegular(
            regularInput(state: .downloadNeeded, hasBorrowLink: true))
        XCTAssertEqual(plan, [.setStateUnregistered, .startBorrow(attemptDownload: true, withCompletion: true)])
    }

    func test_regular_wifiOnlyEnforced_failsWifi() {
        let plan = DownloadStartReducer.reduceRegular(regularInput(wifiOnlyEnforced: true))
        XCTAssertEqual(plan, [.failWifi])
    }

    func test_regular_noRequestSource_logsInvalid() {
        let plan = DownloadStartReducer.reduceRegular(
            regularInput(hasInitedRequest: false, hasAcquisitionURL: false))
        XCTAssertEqual(plan, [.logInvalidRequest(hasURL: false)])
    }

    func test_regular_samlWithCookies_reclaimThenHandleSAML() {
        let plan = DownloadStartReducer.reduceRegular(
            regularInput(state: .SAMLStarted, samlWithCookies: true))
        XCTAssertEqual(plan, [.reclaimDiskSpace, .handleSAML])
    }

    func test_regular_normal_reclaimClearCookiesAddTask() {
        let plan = DownloadStartReducer.reduceRegular(regularInput())
        XCTAssertEqual(plan, [.reclaimDiskSpace, .clearAndSetCookies, .addDownloadTask])
    }

    func test_regular_expiredButNoBorrowLink_fallsToDownload() {
        // Expiry alone does NOT trigger re-borrow — the borrow link is required.
        let plan = DownloadStartReducer.reduceRegular(regularInput(isExpired: true, hasBorrowLink: false))
        XCTAssertEqual(plan, [.reclaimDiskSpace, .clearAndSetCookies, .addDownloadTask])
    }

    func test_regular_downloadNeededButNoBorrowLink_fallsToNormalDownload() {
        // Guards the line-150 `state == .downloadNeeded && hasBorrowLink` AND:
        // an open-access `.downloadNeeded` book (no borrow link) must NOT
        // auto-borrow — it goes straight to the normal download path. (Kills the
        // `&&`→`||` mutant, which would auto-borrow any downloadNeeded book.)
        let plan = DownloadStartReducer.reduceRegular(regularInput(state: .downloadNeeded, hasBorrowLink: false))
        XCTAssertEqual(plan, [.reclaimDiskSpace, .clearAndSetCookies, .addDownloadTask])
    }

    // MARK: - Shape-equality snapshots (proof vs E1 dispatcher service snapshot)

    func test_snapshot_regular_expiredWithBorrow() {
        let log = interpretRegular(regularInput(isExpired: true, hasBorrowLink: true))
        ContractSnapshot.assert(log, named: "regular_expiredWithBorrow_setUnregisteredThenReBorrow")
    }

    func test_snapshot_regular_downloadNeededWithBorrow() {
        let log = interpretRegular(regularInput(state: .downloadNeeded, hasBorrowLink: true))
        ContractSnapshot.assert(log, named: "regular_downloadNeededWithBorrow_setUnregisteredThenAutoBorrow")
    }

    func test_snapshot_regular_wifiOnly() {
        let log = interpretRegular(regularInput(wifiOnlyEnforced: true))
        ContractSnapshot.assert(log, named: "regular_wifiOnlyEnforced_failsWifi_noDownloadTask")
    }

    func test_snapshot_regular_normal() {
        let log = interpretRegular(regularInput())
        ContractSnapshot.assert(log, named: "regular_normal_clearCookiesThenAddDownloadTask")
    }

    func test_snapshot_regular_samlWithCookies() {
        let log = interpretRegular(regularInput(state: .SAMLStarted, samlWithCookies: true), cookieCount: 1)
        ContractSnapshot.assert(log, named: "regular_samlWithCookies_routesSAMLHandler_noDownloadTask")
    }

    func test_snapshot_regular_noAcquisitionURL() {
        let log = interpretRegular(regularInput(hasInitedRequest: false, hasAcquisitionURL: false))
        ContractSnapshot.assert(log, named: "regular_noAcquisitionURL_logsInvalidRequest")
    }

    // MARK: - Helpers

    private static let bookId = "DSR-BOOK"

    private func regularInput(
        state: TPPBookState = .downloadSuccessful,
        isExpired: Bool = false,
        hasBorrowLink: Bool = false,
        wifiOnlyEnforced: Bool = false,
        hasInitedRequest: Bool = false,
        hasAcquisitionURL: Bool = true,
        samlWithCookies: Bool = false
    ) -> DownloadStartReducer.RegularInput {
        .init(state: state, isExpired: isExpired, hasBorrowLink: hasBorrowLink,
              wifiOnlyEnforced: wifiOnlyEnforced, hasInitedRequest: hasInitedRequest,
              hasAcquisitionURL: hasAcquisitionURL, samlWithCookies: samlWithCookies)
    }

    /// Interprets a regular plan into a CallLog using the identical collaborator
    /// labels + arg shape that `RecordingDispatcherDelegate` / registry emit in
    /// `DownloadStartDispatcherContractTests`, so the snapshot is shape-equal.
    private func interpretRegular(
        _ input: DownloadStartReducer.RegularInput,
        cookieCount: Int = 0
    ) -> CallLog {
        let log = CallLog()
        let id = Self.bookId
        for effect in DownloadStartReducer.reduceRegular(input) {
            switch effect {
            case .setStateUnregistered:
                log.record("registry.setState", args: ["bookId": id, "state": "unregistered"])
            case let .startBorrow(attemptDownload, withCompletion):
                log.record("startBorrow",
                           args: ["bookId": id,
                                  "attemptDownload": "\(attemptDownload)",
                                  "hasCompletion": "\(withCompletion)"])
            case .failWifi:
                log.record("failWithWifiRequired", args: ["bookId": id])
            case let .logInvalidRequest(hasURL):
                log.record("logInvalidURLRequest",
                           args: ["bookId": id, "state": "\(input.state.stringValue())", "hasURL": "\(hasURL)"])
            case .reclaimDiskSpace:
                break // unspied collaborator (memory monitor) — records nothing
            case .handleSAML:
                log.record("handleSAMLStartedState", args: ["bookId": id, "cookieCount": "\(cookieCount)"])
            case .clearAndSetCookies:
                log.record("clearAndSetCookies")
            case .addDownloadTask:
                log.record("addDownloadTask", args: ["bookId": id, "hasURL": "true"])
            }
        }
        return log
    }
}
