import XCTest
@testable import TriageBotCore

/// Invariants a remedy ladder must satisfy, enforced when the catalog LOADS.
///
/// Deliberately not test-only lint. The catalog is designed to be server-supplied
/// later for hot updates, so a rule that lives only in the test suite is a rule
/// the shipped app does not have — a hot-pushed catalog could tell every sign-in
/// patron to sign out. Validate the producer, not just the fixture.
///
/// The evidenced rules, from 204 authoring tickets:
///  - sign-in ladders must not contain sign-out or update-the-app. Support
///    prescribed sign-out for sign-in complaints once in 41, and update zero
///    times in 41 — the two cheapest remedies are the two least applicable in
///    the largest category, which is the opposite of what cost-ordering alone
///    would produce.
///  - destructive rungs (sign-out, reinstall) never come first and must always
///    be skippable, because being wrong about them costs the patron their
///    downloaded books.
///  - a ladder is at most three rungs. The quarter of patrons whose problem only
///    staff can fix pay the whole ladder as delay; three cheap rungs is a
///    defensible tax, six is not.
final class CatalogValidationTests: XCTestCase {

    private func rung(_ id: String, _ remedy: Remedy, skippable: Bool = true) -> KBStep {
        KBStep(id: id, instruction: "Do \(remedy.rawValue).", check: "Any change?",
               responses: skippable
                   ? [KBStepResponse(label: "Didn't help", outcome: .advance),
                      KBStepResponse(label: "Fixed it", outcome: .resolved)]
                   : [KBStepResponse(label: "Fixed it", outcome: .resolved)],
               remedy: remedy)
    }

    private func ladder(_ category: KBCategory, _ steps: [KBStep]) -> KBEntry {
        KBEntry(id: "GF-\(category.rawValue)", category: category, kind: .genericFlow,
                symptomKeywords: [], userFacingWorkaround: "A few things to try.",
                userFacingSteps: steps)
    }

    private func validate(_ entries: [KBEntry]) -> [String] {
        CatalogValidator.violations(in: KBCatalog(version: "t", updatedAt: "x", entries: entries))
    }

    func testSigninLadderContainingSignOut_isRejected() {
        let v = validate([ladder(.signin, [rung("a", .pullToRefresh), rung("b", .signOutIn)])])
        XCTAssertFalse(v.isEmpty,
            "sign-out must not be offered to someone whose complaint is that sign-in fails")
    }

    func testSigninLadderContainingUpdateApp_isRejected() {
        XCTAssertFalse(validate([ladder(.signin, [rung("a", .updateApp)])]).isEmpty)
    }

    func testDestructiveRungFirst_isRejected() {
        let v = validate([ladder(.audiobook, [rung("a", .reinstall), rung("b", .pullToRefresh)])])
        XCTAssertFalse(v.isEmpty, "a ladder must not open by deleting the patron's books")
    }

    func testDestructiveRungWithoutASkip_isRejected() {
        let v = validate([ladder(.audiobook, [rung("a", .pullToRefresh),
                                              rung("b", .reinstall, skippable: false)])])
        XCTAssertFalse(v.isEmpty, "a destructive rung must always be refusable")
    }

    func testLadderLongerThanThreeRungs_isRejected() {
        let v = validate([ladder(.audiobook, [rung("a", .pullToRefresh), rung("b", .updateApp),
                                              rung("c", .reopenTitle), rung("d", .toggleNetwork)])])
        XCTAssertFalse(v.isEmpty, "the staff-only quarter pays the whole ladder as delay")
    }

    /// A ladder obeying every rule must pass — a validator that rejects
    /// everything is as useless as one that rejects nothing.
    func testWellFormedLadder_passes() {
        XCTAssertTrue(validate([
            ladder(.audiobook, [rung("a", .updateApp), rung("b", .reopenTitle), rung("c", .reinstall)]),
            ladder(.signin, [rung("d", .pullToRefresh)]),
        ]).isEmpty)
    }

    /// The validator's stated reason for existing is that a hot-pushed catalog
    /// "could tell every sign-in patron to sign out, and nothing on the device
    /// would object". It only ever checked `generic_flow` entries — so a pushed
    /// KNOWN_ISSUE entry in the signin category with a sign-out step did exactly
    /// that and validated clean. The shipped entries happen to comply, but that
    /// is luck rather than enforcement.
    func testSuppressionApplies_toAnyEntryKindNotJustLadders() {
        let sneaky = KBEntry(
            id: "KI-SNEAK", category: .signin, status: .open,
            symptomKeywords: ["cannot sign in"],
            userFacingWorkaround: "Sign out and back in.",
            userFacingSteps: [rung("s1", .signOutIn)])
        XCTAssertFalse(validate([sneaky]).isEmpty,
            "a suppressed remedy must be rejected in ANY entry kind, not only in ladders")
    }

    /// Destructive-first and refusability are safety rules about what we ask a
    /// patron to do. They cannot be scoped to one entry kind either.
    func testDestructiveRulesApply_toAnyEntryKind() {
        let firstDestructive = KBEntry(
            id: "KI-FIRST", category: .audiobook, status: .open,
            symptomKeywords: ["will not play"],
            userFacingWorkaround: "Reinstall.",
            userFacingSteps: [rung("s1", .reinstall), rung("s2", .pullToRefresh)])
        XCTAssertFalse(validate([firstDestructive]).isEmpty,
            "no entry of any kind may open by destroying the patron's downloads")
    }

    /// `otherDevice` is a diagnostic, not a fix — trying another device tells us
    /// something and repairs nothing. It appears in no ladder and no entry step
    /// today; this stops a future author reading the enum as a menu.
    func testOtherDeviceIsNeverARung() {
        let diagnostic = KBEntry(
            id: "GF-diag", category: .audiobook, kind: .genericFlow,
            symptomKeywords: [], userFacingWorkaround: "Try things.",
            userFacingSteps: [rung("s1", .otherDevice)])
        XCTAssertFalse(validate([diagnostic]).isEmpty,
            "trying another device is a diagnostic; it belongs in a question, not a rung")
    }

    /// The shipped catalog must satisfy the same rules it will be held to in
    /// production — the producer check, not just the fixture check.
    func testShippedCatalogIsValid() throws {
        XCTAssertEqual(CatalogValidator.violations(in: try BundledCatalogSource.loadCatalogSync()), [])
    }
}

extension CatalogValidationTests {

    /// The rules must bite at LOAD, not only when a test calls the validator.
    /// A violating ladder is dropped and the rest of the catalog survives — the
    /// bot falls back to its pre-ladder behaviour for that category rather than
    /// losing every entry over one bad rung.
    func testViolatingLadderIsDroppedAtLoad_andTheRestOfTheCatalogSurvives() {
        let bad = ladder(.signin, [rung("x", .signOutIn)])
        let good = KBEntry(id: "KI-KEEP", category: .signin, status: .open,
                           symptomKeywords: ["grayed out"],
                           userFacingWorkaround: "Tap the field anyway.")
        let kb = KnowledgeBase(catalog: KBCatalog(version: "t", updatedAt: "x", entries: [bad, good]))

        XCTAssertNil(kb.genericFlow(for: .signin),
                     "a ladder that breaks a safety rule must not be offered to anyone")
        XCTAssertNotNil(kb.entry(id: "KI-KEEP"),
                        "one bad ladder must not cost the catalog its working entries")
        XCTAssertFalse(kb.validationViolations.isEmpty, "the reason must be reportable, not silent")
    }
}
