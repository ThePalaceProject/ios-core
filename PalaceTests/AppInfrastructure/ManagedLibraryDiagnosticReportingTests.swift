//
//  ManagedLibraryDiagnosticReportingTests.swift
//  PalaceTests
//
//  PP-5221 — reporting a configuration fault once, and recording that we did.
//
//  `ManagedLibraryDiagnosticsTests` asserts the DECISION. This file asserts the
//  part the decision cannot enforce on its own: that the record of "we already
//  told someone about this" is written only when something was actually
//  reported, and that it is keyed on something a malformed payload still has.
//
//  Both of those are failure modes that read as working code. Writing the
//  record unconditionally would silence the report on the one launch where the
//  wait finally expires; keying it on the parsed configuration would re-report
//  the same typo every launch forever, because a payload too malformed to parse
//  has no parsed configuration to key on. Neither shows up as a crash, a
//  failing build, or a wrong value on screen.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedLibraryDiagnosticReportingTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var reporter: RecordingReporter!

    private let goodId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let otherId = "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryDiagnosticReportingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        reporter = RecordingReporter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        reporter = nil
        suiteName = nil
        super.tearDown()
    }

    private func setManaged(_ dictionary: [String: Any]?) {
        if let dictionary {
            defaults.set(dictionary, forKey: ManagedAppConfiguration.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: ManagedAppConfiguration.userDefaultsKey)
        }
    }

    @discardableResult
    private func report(
        _ decision: ManagedLibraryDecision,
        waitHasExpired: Bool = true
    ) -> ManagedLibraryDiagnostic? {
        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: decision,
            waitHasExpired: waitHasExpired,
            defaults: defaults,
            reporter: reporter
        )
    }

    // MARK: - The malformed payload, which is the likely one

    func testAMistypedIdentifier_IsReportedOnce_NotOncePerLaunch() {
        // The case this whole file exists for. A mistyped identifier parses to
        // NO configuration, so a record keyed on the parsed configuration would
        // be nil every time and this device would file a report on every launch
        // until someone fixed it — which, since nobody would be reading the
        // reports by then, is the same as filing none.
        setManaged(["defaultLibraryId": "nort-shore-country-day"])

        for _ in 0..<10 {
            report(.noConfiguration)
        }

        XCTAssertEqual(reporter.reported.count, 1, "reported \(reporter.reported.count) times")
        XCTAssertEqual(reporter.reported.first?.kind, .unusableValue)
    }

    func testAnAdministratorCorrectingAMistypedIdentifier_IsHeardAgain() {
        // What makes reporting-once safe rather than a gag: a changed value is
        // news, so a second wrong attempt reaches us and we can help.
        setManaged(["defaultLibraryId": "first-wrong-value"])
        report(.noConfiguration)

        setManaged(["defaultLibraryId": "second-wrong-value"])
        report(.noConfiguration)

        XCTAssertEqual(reporter.reported.count, 2)
    }

    func testTheRecordSurvivesAPayloadThatParsesToNothing() {
        // Directly: the record must be non-nil even when there is no parsed
        // configuration to take it from.
        setManaged(["defaultLibraryId": "not-a-uuid"])
        report(.noConfiguration)

        XCTAssertNotNil(
            defaults.string(forKey: ManagedLibraryDiagnostics.lastReportedFingerprintKey),
            "nothing was recorded, so the next launch will report the same typo again"
        )
    }

    // MARK: - The record is written only when something was reported

    func testAWaitThatExpiresOnALaterLaunch_StillReachesUs() {
        setManaged(["defaultLibraryId": goodId])

        XCTAssertNil(report(.unresolved, waitHasExpired: false), "still looking")
        XCTAssertNil(report(.unresolved, waitHasExpired: false), "still looking")
        XCTAssertNil(
            defaults.string(forKey: ManagedLibraryDiagnostics.lastReportedFingerprintKey),
            "nothing was reported, so nothing may be recorded — this is the whole contract"
        )

        XCTAssertEqual(report(.unresolved, waitHasExpired: true)?.kind, .libraryNotFound)
        XCTAssertEqual(reporter.reported.count, 1)
    }

    func testASuccessfulLaunch_RecordsNothingAndReportsNothing() {
        setManaged(["defaultLibraryId": goodId])

        for _ in 0..<5 {
            report(.apply(uuid: goodId))
        }

        XCTAssertEqual(reporter.reported, [])
        XCTAssertNil(defaults.string(forKey: ManagedLibraryDiagnostics.lastReportedFingerprintKey))
    }

    func testAnUnmanagedDevice_TouchesNothing() {
        // Almost every install. It must not report, and must not write a key.
        setManaged(nil)

        for _ in 0..<5 {
            report(.noConfiguration)
        }

        XCTAssertEqual(reporter.reported, [])
        XCTAssertNil(defaults.string(forKey: ManagedLibraryDiagnostics.lastReportedFingerprintKey))
    }

    // MARK: - The raw digest itself

    func testTheDigestIsStableAcrossReadsOfTheSamePayload() {
        // `[String: Any]` has no order. An unordered digest would change on its
        // own between launches and re-report a fault that never changed.
        let payload: [String: Any] = [
            "defaultLibraryId": goodId,
            "defaultLibraryCatalogUrl": "https://example.org/catalog",
            "additionalLibraryIds": [otherId, goodId],
            "zzz": "trailing",
            "aaa": "leading"
        ]
        let digests = Set((0..<25).map { _ in
            ManagedAppConfiguration.configurationIdentity(managedDictionary: payload) ?? "nil"
        })

        XCTAssertEqual(digests.count, 1, "digest is not stable: \(digests)")
    }

    func testChangingAnyValue_ChangesTheDigest() {
        let base: [String: Any] = ["defaultLibraryId": goodId]
        let variants: [[String: Any]] = [
            ["defaultLibraryId": otherId],
            ["defaultLibraryId": goodId, "additionalLibraryIds": [otherId]],
            ["defaultLibraryCatalogUrl": "https://example.org/catalog"],
            ["defaultLibraryId": goodId, "defaultLibraryCatalogUrl": "https://example.org/catalog"]
        ]
        let baseDigest = ManagedAppConfiguration.configurationIdentity(managedDictionary: base)

        for variant in variants {
            XCTAssertNotEqual(
                ManagedAppConfiguration.configurationIdentity(managedDictionary: variant),
                baseDigest,
                "a changed payload must read as new: \(variant)"
            )
        }
    }

    func testAnEmptyOrAbsentPayload_HasNoDigest() {
        // An MDM that pushed an empty dictionary and an unmanaged device are
        // the same thing to us: nothing configured, nothing to have reported.
        XCTAssertNil(ManagedAppConfiguration.configurationIdentity(managedDictionary: [:]))
        XCTAssertNil(ManagedAppConfiguration.configurationIdentity(defaults: defaults))
    }

    func testTheDigestCoversValuesTheParserDiscards() {
        // The parsed fingerprint cannot distinguish these — both parse to
        // nothing. The raw digest must, or two different typos deduplicate
        // against each other and the second one is never heard.
        let first = ManagedAppConfiguration.configurationIdentity(managedDictionary: ["defaultLibraryId": "typo-one"])
        let second = ManagedAppConfiguration.configurationIdentity(managedDictionary: ["defaultLibraryId": "typo-two"])

        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: ["defaultLibraryId": "typo-one"]))
        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: ["defaultLibraryId": "typo-two"]))
        XCTAssertNotEqual(first, second)
    }
}

private final class RecordingReporter: ManagedLibraryDiagnosticReporting {
    private(set) var reported: [ManagedLibraryDiagnostic] = []
    func report(_ diagnostic: ManagedLibraryDiagnostic) { reported.append(diagnostic) }
}
