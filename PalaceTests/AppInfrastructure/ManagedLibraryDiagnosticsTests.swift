//
//  ManagedLibraryDiagnosticsTests.swift
//  PalaceTests
//
//  PP-5221 — what the app tells us when a school's configuration is wrong.
//
//  The value being diagnosed is a long hexadecimal identifier an administrator
//  pastes into a form, so a wrong one is a matter of when, not if. The report
//  this produces is the whole difference between "we set it up and nothing
//  happened" and a one-line answer, so two properties have to hold and both are
//  asserted here as a table rather than as scenarios:
//
//  - It distinguishes the cases that lead to different replies. A typo, a
//    well-formed identifier naming a library we cannot find, and a registry
//    that has not landed yet are three different conversations.
//  - It stays quiet otherwise. A report that fires on every slow launch, or
//    every launch of one misconfigured device forever, is noise nobody reads —
//    and a channel nobody reads is the same as no channel.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedLibraryDiagnosticsTests: XCTestCase {

    private let valueA = "id:urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let valueB = "id:urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"

    private let everyDecision: [ManagedLibraryDecision] = [
        .noConfiguration, .alreadyApplied, .registryNotLoaded, .unresolved,
        .apply(uuid: "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e")
    ]

    private func diagnose(
        _ decision: ManagedLibraryDecision,
        warnings: [String] = [],
        waitHasExpired: Bool = true,
        fingerprint: String? = nil,
        lastReported: String? = nil
    ) -> ManagedLibraryDiagnostic? {
        // The helper passes the same value as both the reportable library and
        // the comparison identity, because these tests are about the DECISION.
        // That the two must not be the same value in production is the subject
        // of ManagedLibraryReviewFixesTests.
        ManagedLibraryDiagnostics.diagnostic(
            for: decision,
            warnings: warnings,
            waitHasExpired: waitHasExpired,
            configuredValue: fingerprint ?? valueA,
            identity: fingerprint ?? valueA,
            lastReportedIdentity: lastReported
        )
    }

    // MARK: - A malformed payload is reportable at once
    //
    // No amount of waiting turns a typo into a library, so unlike an unresolved
    // identifier this does not wait on the registry.

    func testAMalformedPayload_IsReportedAsUnusable() {
        let d = diagnose(.noConfiguration,
                         warnings: ["defaultLibraryId is not a UUID: 'north-shore'"])

        XCTAssertEqual(d?.kind, .unusableValue)
        XCTAssertEqual(d?.detail, "defaultLibraryId is not a UUID: 'north-shore'")
    }

    func testAMalformedPayload_DoesNotWaitOnTheRegistry() {
        // The distinction from `.unresolved`: this one is already decidable.
        let d = diagnose(.noConfiguration,
                         warnings: ["defaultLibraryCatalogUrl must use https"],
                         waitHasExpired: false)

        XCTAssertEqual(d?.kind, .unusableValue,
                       "a typo is diagnosable immediately; only a lookup needs the registry")
    }

    func testEveryWarningReachesTheReport() {
        // An administrator who put the right value in two wrong fields needs to
        // hear about both, or they fix one and try again.
        let d = diagnose(.noConfiguration, warnings: ["first thing", "second thing"])

        XCTAssertEqual(d?.detail, "first thing; second thing")
    }

    func testAMalformedPayload_IsUnusableWhateverTheDecisionSays() {
        // The parser dropping a value and the preconfigurator then finding
        // nothing to do are the same fault seen twice. Report the cause.
        for decision in everyDecision {
            XCTAssertEqual(
                diagnose(decision, warnings: ["unusable"])?.kind,
                .unusableValue,
                "decision \(decision) must not mask the parse warning"
            )
        }
    }

    // MARK: - A well-formed identifier that names nothing

    func testAnIdentifierThatResolvesToNothing_IsReportedOnceTheWaitIsOver() {
        let d = diagnose(.unresolved, waitHasExpired: true)

        XCTAssertEqual(d?.kind, .libraryNotFound)
        XCTAssertTrue(d?.detail.contains(valueA) == true,
                      "the report must name the value that failed; got: \(d?.detail ?? "nil")")
    }

    func testAnIdentifierStillBeingLookedUp_IsNotAFault() {
        // This is the one that matters on a cart of devices on a school network
        // in the morning: the configured library is legitimately absent until
        // the network registry lands, so reporting here would fire on every
        // cold launch and bury the real signal.
        XCTAssertNil(diagnose(.unresolved, waitHasExpired: false))
    }

    func testAnUnresolvedConfigurationWithNoValueToName_StaysSilent() {
        // Nothing to tell an administrator to look at. A report that cannot
        // identify the offending configuration wastes the one channel we have.
        XCTAssertNil(
            ManagedLibraryDiagnostics.diagnostic(
                for: .unresolved, warnings: [], waitHasExpired: true,
                configuredValue: nil, identity: nil, lastReportedIdentity: nil
            )
        )
    }

    // MARK: - Silence when nothing is wrong
    //
    // decision          │ reported?
    // ──────────────────┼───────────
    //  noConfiguration  │ no — an unmanaged device, which is almost every device
    //  alreadyApplied   │ no — it worked on an earlier launch
    //  registryNotLoaded│ no — still working
    //  apply            │ no — it worked just now
    //  unresolved       │ only once the wait has expired

    func testTheWorkingAndTheWaitingCases_ReportNothing() {
        for decision: ManagedLibraryDecision in [.noConfiguration, .alreadyApplied,
                                                 .registryNotLoaded,
                                                 .apply(uuid: "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e")] {
            for expired in [true, false] {
                XCTAssertNil(
                    diagnose(decision, waitHasExpired: expired),
                    "\(decision) with waitHasExpired=\(expired) must be silent"
                )
            }
        }
    }

    func testAnUnmanagedDevice_ReportsNothingEver() {
        // No configuration at all: no value, nothing reported before. The
        // overwhelming majority of installs, and they must cost nothing.
        XCTAssertNil(
            ManagedLibraryDiagnostics.diagnostic(
                for: .noConfiguration, warnings: [], waitHasExpired: true,
                configuredValue: nil, identity: nil, lastReportedIdentity: nil
            )
        )
    }

    func testAnMDMRemovingTheConfiguration_IsNotAFault() {
        // Value gone, a value reported previously. Management ending is a
        // normal event, not something to page ourselves about.
        XCTAssertNil(
            ManagedLibraryDiagnostics.diagnostic(
                for: .noConfiguration, warnings: [], waitHasExpired: true,
                configuredValue: nil, identity: nil, lastReportedIdentity: valueA
            )
        )
    }

    // MARK: - Reported once per value, not once per launch

    func testAValueAlreadyReported_IsNotReportedAgain() {
        XCTAssertNil(
            diagnose(.unresolved, fingerprint: valueA, lastReported: valueA),
            "one misconfigured device would otherwise file a report every launch, forever"
        )
    }

    func testTheDeduplicationOutranksEvenAMalformedPayload() {
        // Deliberate ordering: the value is what identifies the report, so a
        // value we have already spoken about is silent no matter how wrong it
        // is. Changing it is what makes it news again — asserted next.
        XCTAssertNil(
            diagnose(.unresolved,
                     warnings: ["still not a UUID"],
                     fingerprint: valueA, lastReported: valueA)
        )
    }

    func testAnAdministratorChangingAWrongValueToAnotherWrongValue_IsReportedAgain() {
        // What makes the deduplication safe rather than a gag: a second attempt
        // is a second report, so we can see them iterating and help.
        let d = diagnose(.unresolved,
                         warnings: ["also not a UUID"],
                         fingerprint: valueB, lastReported: valueA)

        XCTAssertEqual(d?.kind, .unusableValue)
    }

    func testAFirstEverReport_IsNotSuppressedByHavingNothingToCompareTo() {
        XCTAssertNotNil(diagnose(.unresolved, fingerprint: valueA, lastReported: nil))
    }

    // MARK: - The caller contract the deduplication depends on
    //
    // The pure function cannot enforce this on its own: the caller must record
    // the value ONLY when something was actually reported. Recording on every
    // evaluation would mark a value as spoken-for during the pre-expiry window
    // where the answer is deliberately nil — and the fault would then never be
    // reported at all. That is a silent failure of the whole mechanism, so the
    // sequence is asserted rather than left to a comment.

    func testAWaitThatExpiresOnALaterLaunch_StillGetsReported() {
        var lastReported: String? = nil

        func launch(waitHasExpired: Bool) -> ManagedLibraryDiagnostic? {
            let d = ManagedLibraryDiagnostics.diagnostic(
                for: .unresolved, warnings: [], waitHasExpired: waitHasExpired,
                configuredValue: valueA, identity: valueA, lastReportedIdentity: lastReported
            )
            if d != nil { lastReported = valueA }   // the contract: persist only on a report
            return d
        }

        XCTAssertNil(launch(waitHasExpired: false), "first launch: registry never landed")
        XCTAssertNil(launch(waitHasExpired: false), "second launch: same")
        XCTAssertEqual(launch(waitHasExpired: true)?.kind, .libraryNotFound,
                       "third launch waited it out — this is the report that must survive")
        XCTAssertNil(launch(waitHasExpired: true), "and then it goes quiet")
    }

    func testAFaultThatResolvesItself_NeverReports() {
        // The registry lands within the wait on every launch. Nothing was ever
        // wrong and nothing should have been said.
        var lastReported: String? = nil
        for _ in 0..<5 {
            let d = ManagedLibraryDiagnostics.diagnostic(
                for: .apply(uuid: "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"),
                warnings: [], waitHasExpired: true,
                configuredValue: valueA, identity: valueA, lastReportedIdentity: lastReported
            )
            if d != nil { lastReported = valueA }
            XCTAssertNil(d)
        }
        XCTAssertNil(lastReported, "nothing was recorded, because nothing was reported")
    }

    // MARK: - What a support engineer actually reads

    func testTheTwoKinds_ReadAsDifferentProblems() {
        // These land as the searchable top line in Crashlytics. If they were
        // the same string the distinction the whole type exists to draw would
        // be invisible at the point it is read.
        let unusable = ManagedLibraryDiagnostic(kind: .unusableValue, detail: "x").summary
        let notFound = ManagedLibraryDiagnostic(kind: .libraryNotFound, detail: "x").summary

        XCTAssertNotEqual(unusable, notFound)
        XCTAssertFalse(unusable.isEmpty)
        XCTAssertFalse(notFound.isEmpty)
    }

    func testTheDetailNeverEchoesTheComparisonIdentity() {
        // The unit-level form of "nothing that isn't ours".
        //
        // At this level there is no payload, so provenance cannot be witnessed
        // — the end-to-end version of this property lives in
        // `ManagedLibraryReviewFixesTests`, which drives a real managed
        // dictionary carrying a foreign value. What IS checkable here is the
        // structural invariant underneath it: the identity is the comparison
        // value, the detail is the reported value, and the first must never
        // become the second. That is precisely the edit that leaked the whole
        // MDM payload to Crashlytics.
        //
        // An earlier version of this test asserted the detail contained no "@",
        // "barcode", "password", "token" or "pin". It passed throughout the
        // period the code was forwarding the entire foreign payload, because no
        // fixture ever contained a value we did not own. A list of words you
        // thought of can only catch leaks you predicted.
        let identity = "identity-that-must-never-be-reported-4b91"

        let reported = [
            ManagedLibraryDiagnostics.diagnostic(
                for: .unresolved, warnings: [], waitHasExpired: true,
                configuredValue: valueA, identity: identity, lastReportedIdentity: nil
            ),
            ManagedLibraryDiagnostics.diagnostic(
                for: .noConfiguration, warnings: ["defaultLibraryId is not a UUID: 'oops'"],
                waitHasExpired: true,
                configuredValue: valueA, identity: identity, lastReportedIdentity: nil
            )
        ].compactMap { $0 }

        XCTAssertEqual(reported.count, 2, "both cases must report, or this proves nothing")
        for d in reported {
            XCTAssertFalse("\(d.summary) \(d.detail)".contains(identity),
                           "the comparison identity reached the report: \(d.detail)")
        }
    }

    // MARK: - The reporter is a seam, and the seam has to carry the detail

    func testTheReporterForwardsBothTheKindAndTheDetail() {
        // Wiring a reporter that dropped `detail` would leave a searchable line
        // with no value in it — reportable-looking and useless.
        let spy = SpyReporter()
        let d = ManagedLibraryDiagnostic(kind: .libraryNotFound, detail: "configuration \(valueA) …")
        spy.report(d)

        XCTAssertEqual(spy.reported, [d])
        XCTAssertEqual(spy.reported.first?.detail, "configuration \(valueA) …")
    }
}

private final class SpyReporter: ManagedLibraryDiagnosticReporting {
    private(set) var reported: [ManagedLibraryDiagnostic] = []
    func report(_ diagnostic: ManagedLibraryDiagnostic) { reported.append(diagnostic) }
}
