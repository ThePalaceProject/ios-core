import XCTest
@testable import TriageBotCore

/// The `kind` axis lets general-help (how_to) content coexist with known-issue
/// content in one catalog + one classifier, without stretching known-issue
/// status semantics. These pin the backward-compatible decode and the two
/// behaviors that differ for how_to: no version gate, no status badge.
final class KBKindTests: XCTestCase {

    private func decode(_ json: String) throws -> KBEntry {
        try JSONDecoder().decode(KBEntry.self, from: Data(json.utf8))
    }

    func testAbsentKind_defaultsToKnownIssue() throws {
        // Every existing catalog entry omits `kind`; it must decode as a
        // known_issue so the 8-entry corpus keeps working unchanged.
        let entry = try decode("""
        {
          "id": "KI-X", "category": "audiobook", "status": "open",
          "symptom_keywords": ["won't play"],
          "user_facing_workaround": "Tap back, tap again — the second open plays.",
          "confidence_threshold": 0.4, "escalate_anyway": false,
          "trust_level": "authoritative", "visibility": "user_facing"
        }
        """)
        XCTAssertEqual(entry.resolvedKind, .knownIssue)
    }

    func testHowToKind_decodesWithoutStatus() throws {
        let entry = try decode("""
        {
          "id": "HT-renewals", "category": "other", "kind": "how_to",
          "symptom_keywords": ["renew", "extend loan"],
          "user_facing_workaround": "Palace doesn't renew loans in the app — the book returns itself when the loan ends. To keep reading, borrow it again or place a hold.",
          "confidence_threshold": 0.4, "escalate_anyway": false,
          "trust_level": "authoritative", "visibility": "user_facing"
        }
        """)
        XCTAssertEqual(entry.resolvedKind, .howTo)
        XCTAssertNil(entry.status, "how_to entries carry an answer, not a known-issue status")
    }

    func testHowToEntry_isNeverVersionGated() {
        // A how_to entry has no fix version; it must surface even for a patron
        // on the very latest build (a known-issue fixed_in entry would be hidden).
        let howTo = KBEntry(
            id: "HT-switch", category: .library, kind: .howTo,
            symptomKeywords: ["switch library", "change library", "add library"],
            userFacingWorkaround: "Tap the Palace logo in the top-left, then Add Library, and search for your library by name.",
            confidenceThreshold: 0.1
        )
        let kb = KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: [howTo]))
        let current = ContextSnapshot(
            appVersion: "3.3.0", appBuild: "488", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        let result = LocalClassifier().classify(
            userText: "how do I switch library and add library",
            category: .library, context: current, knowledgeBase: kb
        )

        guard case .suggest(let id) = result.decision else {
            return XCTFail("how_to entry must surface on a current build; got \(result.decision)")
        }
        XCTAssertEqual(id, "HT-switch")
    }
}
