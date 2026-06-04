import XCTest
@testable import TriageBotCore

final class SemanticVersionTests: XCTestCase {

    // MARK: - Parsing

    func testParse_threeComponents() {
        XCTAssertEqual(SemanticVersion("3.2.0"), SemanticVersion(major: 3, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("3.10.5"), SemanticVersion(major: 3, minor: 10, patch: 5))
    }

    func testParse_missingComponentsCoerceToZero() {
        XCTAssertEqual(SemanticVersion("3.2"), SemanticVersion(major: 3, minor: 2, patch: 0))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(major: 3, minor: 0, patch: 0))
    }

    func testParse_stripsLeadingV() {
        XCTAssertEqual(SemanticVersion("v3.2.1"), SemanticVersion(major: 3, minor: 2, patch: 1))
    }

    func testParse_returnsNilForGarbage() {
        XCTAssertNil(SemanticVersion("next release"))
        XCTAssertNil(SemanticVersion("TBD"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("unknown"))
    }

    // MARK: - Comparison

    func testCompare_componentWiseNotLexicographic() {
        // The classic 3.10 vs 3.2 trap — lexicographic compare gets it wrong.
        XCTAssertTrue(SemanticVersion("3.2.0")! < SemanticVersion("3.10.0")!)
        XCTAssertTrue(SemanticVersion("3.10.0")! > SemanticVersion("3.2.0")!)
    }

    func testCompare_equalVersions() {
        XCTAssertEqual(SemanticVersion("3.2.0"), SemanticVersion("3.2.0"))
        XCTAssertEqual(SemanticVersion("3.2"), SemanticVersion("3.2.0"))
    }

    func testCompare_patchLevel() {
        XCTAssertTrue(SemanticVersion("3.2.0")! < SemanticVersion("3.2.1")!)
        XCTAssertTrue(SemanticVersion("3.2.1")! >= SemanticVersion("3.2.0")!)
    }

    // MARK: - FixVersionGate

    func testGate_userOnFixVersion_returnsTrue() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .fixedIn,
            fixedInVersion: "3.2.0",
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertTrue(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.2.0"))
    }

    func testGate_userPastFixVersion_returnsTrue() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .fixedIn,
            fixedInVersion: "3.2.0",
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertTrue(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.3.0"))
        XCTAssertTrue(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "4.0.0"))
    }

    func testGate_userBeforeFixVersion_returnsFalse() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .fixedIn,
            fixedInVersion: "3.2.0",
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertFalse(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.1.0"))
        XCTAssertFalse(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.0.3"))
    }

    func testGate_entryWithoutFixVersion_returnsFalse() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .open,
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertFalse(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.2.0"))
    }

    func testGate_missingUserVersion_returnsFalse() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .fixedIn,
            fixedInVersion: "3.2.0",
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertFalse(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: nil))
    }

    func testGate_unparseableFixVersion_returnsFalse() {
        let entry = KBEntry(
            id: "x", category: .audiobook, status: .fixedIn,
            fixedInVersion: "next release",
            symptomKeywords: [], userFacingWorkaround: ""
        )
        XCTAssertFalse(FixVersionGate.userAlreadyHasFix(for: entry, userAppVersion: "3.2.0"))
    }

    // MARK: - End-to-end via classifier

    func testClassifier_filtersOutFixedEntries_whenUserHasTheFix() {
        let kb = KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-FIXED",
                category: .audiobook,
                status: .fixedIn,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["spinning", "won't play"],
                userFacingWorkaround: "Update the app.",
                confidenceThreshold: 0.1
            )
        ]))
        // User already on 3.2.0 — fixed entry should be filtered out
        let userOnFix = ContextSnapshot(
            appVersion: "3.2.0", appBuild: "1", osVersion: "26", deviceModel: "x"
        )
        let result = LocalClassifier().classify(
            userText: "audiobook spinning, won't play",
            category: .audiobook,
            context: userOnFix,
            knowledgeBase: kb
        )
        XCTAssertEqual(result.decision, .escalate,
            "User on fix version should escalate, not see the workaround for a bug they supposedly already have fixed")
    }

    func testClassifier_surfacesFixedEntries_whenUserBeforeFix() {
        let kb = KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-FIXED",
                category: .audiobook,
                status: .fixedIn,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["spinning", "won't play"],
                userFacingWorkaround: "Update the app.",
                confidenceThreshold: 0.1
            )
        ]))
        let userBehind = ContextSnapshot(
            appVersion: "3.1.0", appBuild: "1", osVersion: "26", deviceModel: "x"
        )
        let result = LocalClassifier().classify(
            userText: "audiobook spinning, won't play",
            category: .audiobook,
            context: userBehind,
            knowledgeBase: kb
        )
        if case .suggest(let id) = result.decision {
            XCTAssertEqual(id, "KI-FIXED", "User behind the fix should see the workaround")
        } else {
            XCTFail("Expected suggest for user behind the fix, got \(result.decision)")
        }
    }
}
