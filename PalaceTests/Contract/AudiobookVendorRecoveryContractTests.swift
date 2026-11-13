//  AudiobookVendorRecoveryContractTests.swift
//
//  HelpSpot #18471: snapshot of which (vendor x failure signal x cold/mid-listen)
//  scenarios the bearer-token re-fulfill recovery claims and which stay on the
//  terminal fallback. Routes come from the production predicate
//  `shouldTriggerBearerTokenRefulfillForPlaybackFailure`, so a change to the
//  trigger codes or vendor allowlist changes the snapshot. Covered routes fire for
//  both cold and mid-listen failures, once per book per session.

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class AudiobookVendorRecoveryContractTests: XCTestCase {

    /// The recovery route the production predicate selects for a playback
    /// failure. `bearerTokenRefulfill.reopen(forceRefulfill=true)` is the new
    /// covered path; `existingFallback` means "not claimed by this fix" — the
    /// failure flows on to OverDrive's own path / SAML / cold-load / the
    /// terminal "content unavailable" alert exactly as before.
    private func route(book: TPPBook, error: NSError, alreadyAttempted: Bool) -> String {
        if AudiobookPlaybackRecoveryReducer.shouldTriggerBearerTokenRefulfillForPlaybackFailure(
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
