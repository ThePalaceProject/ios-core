//
//  TPPCirculationAnalyticsRequestShapeContractTests.swift
//  PalaceTests
//
//  Contract test for the god-class decomposition campaign — Wave 1c
//  (misfiles + inversions). See docs/architecture/god-class-decomposition-plan.md
//  §4 Wave 1c and §3b cycle 3.
//
//  Target: `Palace/OPDS2/Service/TPPCirculationAnalytics.swift` — a
//  circulation-domain network client relocated OUT of `Palace/Logging/` in
//  Wave 1c (killing folder-cycle #3, Logging↔Network). The move is a pure file
//  relocation, so this test pins the offline-retry enqueue SHAPE so the
//  relocation is provably behavior-preserving.
//
//  SEAM: RESOLVED (Wave 1c). Two blockers the pre-wave placeholder documented
//  are now dissolved:
//    1. `addToOfflineAnalyticsQueue(_:_:accountsManager:requestProvider:offlineQueue:)`
//       is now `internal` (was `private static`) and takes all three
//       dependencies as injected seams — `accountsManager` (widened to the
//       `TPPCurrentLibraryAccountProvider` protocol), `requestProvider`
//       (`AuthorizedRequestProviding`), and `offlineQueue`
//       (`OfflineRequestEnqueuing`) — the latter two are PalaceNetwork-package
//       protocols. Spies inject via those params; no live container is touched.
//    2. The un-interceptable ephemeral `URLSession` in `post(_:withURL:)` is
//       still un-observable, so the LIVE outbound request is NOT snapshotted
//       here — only the offline-enqueue derivation is (that is the injectable
//       contract, and the one the offline re-wire follow-up will build on).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceNetwork

@MainActor
final class TPPCirculationAnalyticsRequestShapeContractTests: XCTestCase {

    // The two tests inject all three seams as local spies and never touch a
    // singleton or the production container (`addToOfflineAnalyticsQueue` reaches
    // AppContainer.production() only via defaulted args, which the tests always
    // override). There is no global/spy state that outlives a test; this
    // tearDown is the explicit no-shared-state contract for the bundle.
    override func tearDown() {
        super.tearDown()
    }

    /// CONTRACT: no current account → libraryID pinned to "" (not nil, not a
    /// crash), request-provider consulted exactly once for the event URL, and
    /// the enqueue is a GET of that URL with the provider's auth headers and
    /// nil updateID/parameters.
    func testOfflineEnqueue_noAccount_pinnedShape_GET_emptyLibraryID() {
        let log = CallLog()
        let url = URL(string: "https://analytics.example.org/events/open_book")!

        TPPCirculationAnalytics.addToOfflineAnalyticsQueue(
            "open_book", url,
            accountsManager: SpyAccountProvider(account: nil),
            requestProvider: SpyRequestProvider(log: log),
            offlineQueue: SpyOfflineQueue(log: log)
        )

        // Inline CallLog equality (not file-based ContractSnapshot) so the test is
        // GREEN on first CI run — no external __Snapshots__ baseline to record.
        let snap = log.snapshot()
        XCTAssertEqual(
            snap.map(\.method),
            ["requestProvider.authorizedRequest", "offlineQueue.enqueueOfflineRequest"],
            "consult the request-provider once for the event URL, then enqueue once"
        )
        let enqueue = snap.first { $0.method == "offlineQueue.enqueueOfflineRequest" }
        XCTAssertEqual(enqueue?.args["libraryID"], "", "no current account → libraryID pinned to empty string, not nil/crash")
        XCTAssertEqual(enqueue?.args["method"], "GET", "offline analytics enqueue is a GET")
        XCTAssertEqual(enqueue?.args["url"], url.absoluteString, "enqueues the event URL")
        XCTAssertEqual(enqueue?.args["headers"], "Authorization=Bearer contract-test-token",
                       "enqueue must carry the request-provider's auth headers (kills a headers:nil mutant)")
        XCTAssertEqual(enqueue?.args["updateID"], "nil", "no updateID")
        XCTAssertEqual(enqueue?.args["parameters"], "nil", "no body parameters")
    }

    /// CONTRACT: with a current account, libraryID is that account's uuid —
    /// kills a `?? ""`-arm swap or a uuid→name mutant. Uses the shared fixture
    /// mock (deterministic uuid from OPDS2CatalogsFeed.json).
    func testOfflineEnqueue_withAccount_libraryIDIsAccountUUID() {
        let log = CallLog()
        let url = URL(string: "https://analytics.example.org/events/open_book")!

        let accounts = TPPCurrentLibraryAccountProviderMock()
        TPPCirculationAnalytics.addToOfflineAnalyticsQueue(
            "open_book", url,
            accountsManager: accounts,
            requestProvider: SpyRequestProvider(log: log),
            offlineQueue: SpyOfflineQueue(log: log)
        )

        // Inline CallLog equality (not file-based ContractSnapshot) — GREEN on
        // first CI run. Asserts the libraryID RELATIONSHIP (== the account uuid),
        // stronger than a snapshotted magic string.
        let snap = log.snapshot()
        XCTAssertEqual(
            snap.map(\.method),
            ["requestProvider.authorizedRequest", "offlineQueue.enqueueOfflineRequest"],
            "consult the request-provider once, then enqueue once"
        )
        let enqueue = snap.first { $0.method == "offlineQueue.enqueueOfflineRequest" }
        XCTAssertEqual(enqueue?.args["libraryID"], accounts.currentAccount?.uuid,
                       "with a current account, libraryID must be that account's uuid (kills the ?? \"\" arm + uuid→name mutant)")
        XCTAssertFalse(enqueue?.args["libraryID"]?.isEmpty ?? true, "libraryID is non-empty when an account exists")
        XCTAssertEqual(enqueue?.args["method"], "GET")
        XCTAssertEqual(enqueue?.args["url"], url.absoluteString)
    }

    // LATENT-BUG NOTE (discovered while characterizing; DEAD gate now deleted,
    // live fix DEFERRED): the pre-move `handleFailure` gated the offline enqueue
    // on `NetworkQueue.StatusCodes.contains(httpResponse.statusCode)` — but
    // StatusCodes are NEGATIVE NSURLError codes while `statusCode` is a POSITIVE
    // HTTP status, so the branch was dead since inception (and on timeout
    // `response` is nil). Wave 1c DELETED that dead gate (behavior-identical:
    // nothing was ever enqueued) rather than keep the last `NetworkQueue`
    // type-name in the relocated file. Actually making offline analytics retry
    // live is a behavior change (first-ever enqueues → retry/dedup semantics)
    // and is the filed follow-up; this snapshot is its landing pad.
}

// MARK: - Spies

/// @objc protocol ⇒ NSObject subclass.
private final class SpyAccountProvider: NSObject, TPPCurrentLibraryAccountProvider {
    let currentAccount: Account?
    init(account: Account?) { self.currentAccount = account }
}

private final class SpyRequestProvider: AuthorizedRequestProviding, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func authorizedRequest(for url: URL) -> URLRequest {
        log.record("requestProvider.authorizedRequest", args: ["url": url.absoluteString])
        var request = URLRequest(url: url)
        request.setValue("Bearer contract-test-token", forHTTPHeaderField: "Authorization")
        return request
    }
}

private final class SpyOfflineQueue: OfflineRequestEnqueuing, @unchecked Sendable {
    let log: CallLog
    init(log: CallLog) { self.log = log }
    func enqueueOfflineRequest(libraryID: String, updateID: String?, url: URL,
                               method: HTTPMethod, parameters: Data?, headers: [String: String]?) {
        log.record("offlineQueue.enqueueOfflineRequest", args: [
            "libraryID": libraryID,
            "updateID": updateID ?? "nil",
            "url": url.absoluteString,
            "method": method.rawValue,
            "parameters": parameters.map { "\($0.count)B" } ?? "nil",
            "headers": (headers ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        ])
    }
}
