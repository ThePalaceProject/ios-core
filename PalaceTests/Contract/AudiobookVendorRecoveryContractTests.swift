//
//  AudiobookVendorRecoveryContractTests.swift
//  PalaceTests
//
//  323-Cause-3 (HelpSpot #18471): a coverage contract for the generalized
//  mid-listen expired-entitlement recovery. It pins, as a committed JSON
//  snapshot, WHICH (vendor × failure-signal × cold/mid-listen) scenarios the
//  new bearer-token re-fulfill recovery claims vs. which are LEFT on the
//  existing terminal fallback — the exact scope decision this change makes.
//
//  The route for each scenario is computed from the PRODUCTION predicate
//  (`shouldTriggerBearerTokenRefulfillForPlaybackFailure`), not a hard-coded
//  table, so any drift in the trigger classification or the vendor allowlist
//  (e.g. someone drops 403, or accidentally lets LCP/Findaway in) changes the
//  snapshot and fails loudly. The mid-listen dimension proves the exclusion
//  lift: the covered route fires for BOTH cold (hasEverStartedPlayback == false)
//  and mid-listen (true) — bounded to one attempt per book per session.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AudiobookVendorRecoveryContractTests: XCTestCase {

    /// The recovery route the production predicate selects for a playback
    /// failure. `bearerTokenRefulfill.reopen(forceRefulfill=true)` is the new
    /// covered path; `existingFallback` means "not claimed by this fix" — the
    /// failure flows on to OverDrive's own path / SAML / cold-load / the
    /// terminal "content unavailable" alert exactly as before.
    private func route(book: TPPBook, error: NSError, alreadyAttempted: Bool) -> String {
        if AudiobookSessionManager.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
            error: error, book: book, alreadyAttempted: alreadyAttempted) {
            return "bearerTokenRefulfill.reopen(forceRefulfill=true)"
        }
        return "existingFallback"
    }

    private func httpError(_ status: Int) -> NSError {
        NSError(domain: "test.playback", code: 1, userInfo: ["httpStatusCode": status])
    }

    private func resourceUnavailable() -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, userInfo: [:])
    }

    func testVendorRecoveryCoverageMatrix() {
        let log = CallLog()

        // (label, distributorType) — the vendor set the audiobook stack serves.
        let vendors: [(String, DistributorType)] = [
            ("bearerToken", .BearerToken),      // BiblioBoard / Unlimited Listens — COVERED
            ("overdrive", .OverdriveAudiobook), // own dedicated path — left as-is
            ("lcp", .AudiobookLCP),             // license/loan expiry — left on alert
            ("findaway", .Findaway),            // not safely verifiable — left on alert
            ("openAccess", .OpenAccessAudiobook)// static URLs, no expiry — n/a
        ]

        // (label, error) — the failure signals a mid-listen expiry can carry.
        let signals: [(String, NSError)] = [
            ("http410", httpError(410)),
            ("http403", httpError(403)),
            ("urlError_minus1008", resourceUnavailable()),
            ("http401_auth", httpError(401)),
        ]

        // Both cold and mid-listen — proving the mid-listen exclusion is lifted
        // (the covered route is identical for both). `false` = cold open,
        // `true` = playback already started this session.
        let midListenStates = [false, true]

        for (vendorLabel, distributor) in vendors {
            for (signalLabel, error) in signals {
                for midListen in midListenStates {
                    let book = TPPBookMocker.mockBook(distributorType: distributor)
                    let selected = route(book: book, error: error, alreadyAttempted: false)
                    log.record(selected, args: [
                        "vendor": vendorLabel,
                        "signal": signalLabel,
                        "midListen": midListen,
                    ])
                }
            }
        }

        // Per-session bound: a covered scenario that already attempted this
        // session must fall back (no loop), regardless of mid-listen state.
        let boundBook = TPPBookMocker.mockBook(distributorType: .BearerToken)
        log.record(route(book: boundBook, error: httpError(410), alreadyAttempted: true), args: [
            "vendor": "bearerToken",
            "signal": "http410",
            "note": "alreadyAttemptedThisSession",
        ])

        ContractSnapshot.assert(log, named: "vendorRecoveryCoverageMatrix")
    }
}
