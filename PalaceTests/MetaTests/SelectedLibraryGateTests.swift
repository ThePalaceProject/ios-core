//
//  Self-test for the selected-library gate: the auditor fires on a synthetic
//  polluter and stays silent on clean state. Subclasses `PalaceTestCase` because
//  one test writes the live key; it restores the old value via `defer` before
//  tearDown, so the inherited gate also exercises itself.
//

import XCTest
@testable import Palace

@MainActor
final class SelectedLibraryGateTests: PalaceTestCase {

    private let fixture = "11111111-2222-3333-4444-555555555555"

    // MARK: - Detector proves it FIRES on a synthetic polluter

    /// The decisive self-test: a test that left a different library selected
    /// MUST produce exactly one violation. If this returns empty, the gate is
    /// inert and a leaked fixture uuid reaches the next patron on that device.
    func testSelectedLibraryViolations_libraryReplaced_producesExactlyOneViolation() {
        let violations = RuntimeQuiescenceAuditor.selectedLibraryViolations(
            before: "real-library-uuid",
            after: fixture
        )

        XCTAssertEqual(violations.count, 1,
                       "A test that repointed the selected library is the documented polluter")
        XCTAssertEqual(violations.first?.invariant,
                       "UserDefaults.standard[\(currentAccountIdentifierKey)] unchanged by the test",
                       "The flagged invariant must name the key it guards")
    }

    /// Seeding the key where nothing was selected is the common shape — a fresh
    /// simulator has no library — so it must fire too.
    func testSelectedLibraryViolations_seededFromAbsent_fires() {
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: nil, after: fixture).count, 1,
            "Seeding a library where none was selected must trip the gate"
        )
    }

    /// Clearing a library the device had selected is equally a change, and the
    /// restore branch for it differs, so it is pinned separately.
    func testSelectedLibraryViolations_clearedToAbsent_fires() {
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: fixture, after: nil).count, 1,
            "Clearing the selected library must trip the gate"
        )
    }

    /// The message must name both ends and the remediation, so the engineer who
    /// lands a polluter knows the fix from the failure line alone.
    func testSelectedLibraryViolations_message_isActionable() {
        let detail = RuntimeQuiescenceAuditor.selectedLibraryViolations(
            before: nil,
            after: fixture
        ).first?.detail ?? ""

        XCTAssertTrue(detail.contains(fixture), "The message must name what was left behind")
        XCTAssertTrue(detail.contains("no library"), "The message must name what it should have been")
        XCTAssertTrue(detail.contains("testUserDefaults") || detail.contains("tearDown"),
                      "The message must tell the engineer how to stop writing .standard")
    }

    // MARK: - Detector proves it does NOT false-positive on clean state

    /// Symmetric self-test: a test that left the key alone must not fire. A gate
    /// that reddens clean state trains everyone to ignore it.
    func testSelectedLibraryViolations_unchanged_producesNoViolations() {
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: fixture, after: fixture).isEmpty,
            "A test that left the selected library alone must not trip the gate"
        )
    }

    /// Absent on both sides is the state of a fresh simulator, and must be quiet.
    func testSelectedLibraryViolations_absentOnBothSides_producesNoViolations() {
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: nil, after: nil).isEmpty,
            "No library selected either side is unchanged, not a violation"
        )
    }

    // MARK: - The key is not type-pinned

    /// The key can hold a legacy `Int` (`SEMigrations` reads one), so comparison
    /// must not narrow to `String`. Sampling such a value through
    /// `string(forKey:)` answers `nil` on both sides, which would read as
    /// unchanged while the overwrite stood.
    func testSelectedLibraryViolations_legacyIntegerValue_comparesWithoutNarrowing() {
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: 3, after: 3).isEmpty,
            "An unchanged legacy integer must not trip the gate"
        )
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.selectedLibraryViolations(before: 3, after: fixture).count, 1,
            "A legacy integer replaced by a fixture uuid is the leak the gate exists for, "
            + "and string(forKey:) would have read nil on both sides"
        )
    }

    // MARK: - Live capture reads the real key

    /// Proves `captureSelectedLibrary()` reflects the live value rather than a
    /// constant, so the tearDown gate audits real state. Restores the old value
    /// via `defer` before tearDown, so this test leaves `.standard` as it found
    /// it and the inherited gate stays green.
    func testCaptureSelectedLibrary_reflectsTheLiveValue() {
        let original = UserDefaults.standard.object(forKey: currentAccountIdentifierKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: currentAccountIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
            }
        }

        UserDefaults.standard.set(fixture, forKey: currentAccountIdentifierKey)
        XCTAssertEqual(RuntimeQuiescenceAuditor.captureSelectedLibrary() as? String, fixture,
                       "captureSelectedLibrary() must read the value just written")

        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
        XCTAssertNil(RuntimeQuiescenceAuditor.captureSelectedLibrary(),
                     "captureSelectedLibrary() must report absence, not a stale read")
    }
}
