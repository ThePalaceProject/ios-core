//
//  ManagedLibraryReviewFixesTests.swift
//  PalaceTests
//
//  Three defects found in review of PR #1508, each pinned by a test that fails
//  against the code as it was.
//
//  They are grouped because they share a cause worth naming: a single value was
//  being asked to do two jobs. The parsed configuration's fingerprint was the
//  comparison key, so a payload that parsed to nothing had no key at all; then
//  the raw payload became the comparison key, and the reporting path embedded
//  it in a Crashlytics report. One value, two privileges, and the privileges
//  disagreed.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedLibraryReviewFixesTests: XCTestCase {

    private let goodId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let otherId = "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var reporter: CapturingReporter!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryReviewFixesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        reporter = CapturingReporter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        reporter = nil
        suiteName = nil
        super.tearDown()
    }

    private func setManaged(_ dictionary: [String: Any]) {
        defaults.set(dictionary, forKey: ManagedAppConfiguration.userDefaultsKey)
    }

    // MARK: - 1. Nothing belonging to the school's MDM may leave the device
    //
    // The managed dictionary is the MDM's, not ours. It may carry settings for
    // other purposes today and sensitive ones tomorrow. Only values under our
    // own keys, typed from a document we wrote, are ours to report.

    func testAReportNeverCarriesAPayloadKeyWeDoNotOwn() {
        // A school's MDM sends its own keys alongside ours, which is ordinary
        // and entirely their business.
        setManaged([
            "defaultLibraryId": goodId,
            "districtStudentIdentifier": "student-88421",
            "internalNotes": "Ms Okafor's cart, room 12"
        ])

        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: .unresolved, waitHasExpired: true,
            defaults: defaults, reporter: reporter
        )

        let sent = reporter.reported.map { "\($0.summary) \($0.detail)" }.joined(separator: " ")
        XCTAssertFalse(sent.isEmpty, "the run must actually report, or this proves nothing")
        for foreign in ["districtStudentIdentifier", "student-88421", "internalNotes", "Okafor", "room 12"] {
            XCTAssertFalse(sent.contains(foreign),
                           "'\(foreign)' is the MDM's, not ours, and reached a report: \(sent)")
        }
    }

    func testTheReportStillNamesTheLibraryTheAdministratorAskedFor() {
        // Redaction that removes the useful part is not a fix. The whole
        // purpose is telling an administrator which value failed.
        setManaged(["defaultLibraryId": goodId, "someOtherVendorKey": "x"])

        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: .unresolved, waitHasExpired: true,
            defaults: defaults, reporter: reporter
        )

        XCTAssertEqual(reporter.reported.first?.kind, .libraryNotFound)
        XCTAssertTrue(reporter.reported.first?.detail.contains(goodId) == true,
                      "got: \(reporter.reported.first?.detail ?? "nil")")
    }

    func testTheComparisonValueIsNotTheContent() {
        // The identity exists to answer "same configuration?" and nothing else.
        // If it were reversible, redacting the report would be pointless.
        let identity = ManagedAppConfiguration.configurationIdentity(managedDictionary: [
            "defaultLibraryId": goodId,
            "secretish": "a-value-nobody-should-see"
        ])

        XCTAssertNotNil(identity)
        XCTAssertFalse(identity!.contains("a-value-nobody-should-see"))
        XCTAssertFalse(identity!.contains(goodId))
    }

    func testTheIdentityIsStableAcrossReads() {
        // It is compared against a value stored on a previous launch, so an
        // identity that varies run to run would re-report a fault that never
        // moved. Swift's own hashing is seeded per process and cannot serve.
        let payload: [String: Any] = ["defaultLibraryId": goodId, "z": "1", "a": [otherId, goodId]]
        let seen = Set((0..<20).map {
            _ in ManagedAppConfiguration.configurationIdentity(managedDictionary: payload) ?? "nil"
        })
        XCTAssertEqual(seen.count, 1, "identity is not stable: \(seen)")
    }

    func testAChangeUnderAnyKeyIsANewIdentity() {
        let base: [String: Any] = ["defaultLibraryId": goodId]
        for variant in [["defaultLibraryId": otherId],
                        ["defaultLibraryId": goodId, "unrelatedVendorKey": "added"]] as [[String: Any]] {
            XCTAssertNotEqual(
                ManagedAppConfiguration.configurationIdentity(managedDictionary: variant),
                ManagedAppConfiguration.configurationIdentity(managedDictionary: base),
                "a changed payload must read as new: \(variant)"
            )
        }
    }

    // MARK: - 2. Two different malformed payloads are two different faults
    //
    // Both parse to nothing. Keyed on the parsed configuration they are
    // indistinguishable, so the second one is silently swallowed — and a
    // mistyped identifier is the single most likely fault in the field.

    func testASecondDifferentTypo_IsNotMistakenForTheFirst() {
        setManaged(["defaultLibraryId": "typo-one"])
        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: .noConfiguration, waitHasExpired: true,
            defaults: defaults, reporter: reporter
        )

        setManaged(["defaultLibraryId": "typo-two"])
        ManagedLibraryDiagnostics.reportIfNeeded(
            decision: .noConfiguration, waitHasExpired: true,
            defaults: defaults, reporter: reporter
        )

        XCTAssertEqual(reporter.reported.count, 2,
                       "an administrator's second attempt must be heard")
    }

    func testAMalformedPayloadHasAnIdentityAtAll() {
        // The root of it: a payload that parses to nothing still has to be
        // distinguishable from another payload that parses to nothing.
        let first = ManagedAppConfiguration.configurationIdentity(managedDictionary: ["defaultLibraryId": "typo-one"])
        let second = ManagedAppConfiguration.configurationIdentity(managedDictionary: ["defaultLibraryId": "typo-two"])

        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: ["defaultLibraryId": "typo-one"]))
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - 3. The wait belongs to the configuration, not to the launch
    //
    // An MDM can change the configuration while the app is starting, which is
    // precisely the morning-on-a-school-network case the wait exists for.

    func testANewConfigurationGetsItsOwnGracePeriod() {
        // The defect: configuration A had been waiting 16s, past the limit.
        // Configuration B arrives and inherits that, so it falls straight
        // through to the picker having never once been given a chance.
        var clock = ManagedLibraryWaitClock()
        let t0 = Date()

        XCTAssertEqual(clock.elapsed(for: "config-A", now: t0), 0, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(for: "config-A", now: t0.addingTimeInterval(16)), 16, accuracy: 0.001)

        XCTAssertEqual(clock.elapsed(for: "config-B", now: t0.addingTimeInterval(16)), 0, accuracy: 0.001,
                       "a configuration that just arrived has not been waited on at all")
    }

    func testTheGracePeriodIsActuallyUsableAfterAChange() {
        // Stated as the behaviour that matters rather than as a clock reading:
        // the new configuration must still be inside the wait.
        var clock = ManagedLibraryWaitClock()
        let t0 = Date()
        _ = clock.elapsed(for: "config-A", now: t0)
        _ = clock.elapsed(for: "config-A", now: t0.addingTimeInterval(60))

        let elapsed = clock.elapsed(for: "config-B", now: t0.addingTimeInterval(60))
        let step = ManagedLibraryPreconfigurator.launchStep(for: .unresolved, elapsed: elapsed)

        XCTAssertEqual(step, .waitForRegistry,
                       "the new configuration was denied its wait and went straight to the picker")
    }

    func testAnUnchangedConfigurationKeepsAccumulating() {
        // The wait must still expire, or a misconfigured device never reaches
        // a usable picker — strictly worse than today.
        var clock = ManagedLibraryWaitClock()
        let t0 = Date()
        _ = clock.elapsed(for: "config-A", now: t0)

        let elapsed = clock.elapsed(for: "config-A", now: t0.addingTimeInterval(60))
        XCTAssertEqual(ManagedLibraryPreconfigurator.launchStep(for: .unresolved, elapsed: elapsed),
                       .presentPicker)
    }

    func testAnUnmanagedDeviceHasNoConfigurationToWaitFor() {
        var clock = ManagedLibraryWaitClock()
        let t0 = Date()
        XCTAssertEqual(clock.elapsed(for: nil, now: t0), 0, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(for: nil, now: t0.addingTimeInterval(30)), 30, accuracy: 0.001,
                       "nil is a state like any other, not a reset on every call")
    }
}

private final class CapturingReporter: ManagedLibraryDiagnosticReporting {
    private(set) var reported: [ManagedLibraryDiagnostic] = []
    func report(_ diagnostic: ManagedLibraryDiagnostic) { reported.append(diagnostic) }
}
