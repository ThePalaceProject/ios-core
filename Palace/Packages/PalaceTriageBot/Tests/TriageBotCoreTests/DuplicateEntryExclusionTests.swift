import XCTest
@testable import TriageBotCore

/// A `duplicate_of` entry is bookkeeping — it points at the entry that actually
/// holds the answer — so it must never reach a patron as a candidate.
///
/// Written because a mutation run on `entries(matchableFrom:)` found the
/// duplicate guard unprotected: flipping `return false` to `return true` there
/// left all 409 tests green. Nothing caught it because the SHIPPED catalog
/// currently has no `duplicate_of` entry, so the guard is dead code today and
/// live the moment support marks its first duplicate. That is exactly the case
/// a corpus test cannot reach and a synthetic one can.
final class DuplicateEntryExclusionTests: XCTestCase {

    private func kb(status: KBStatus?, kind: KBKind?) -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "DUP-1",
                category: .library,
                kind: kind,
                status: status,
                symptomKeywords: ["wrong library"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.1
            )
        ]))
    }

    func testDuplicateEntry_IsNotACandidate_ForItsOwnCategory() {
        let entries = kb(status: .duplicateOf, kind: nil).entries(matchableFrom: .library)
        XCTAssertTrue(entries.isEmpty, "a duplicate_of entry must never be offered to a patron")
    }

    /// The how-to widening must not smuggle duplicates in through the back door:
    /// a duplicated how-to is now a candidate in EVERY category, so if the
    /// duplicate guard were dropped it would be wrong six times over.
    func testDuplicateHowTo_IsNotACandidate_InAnyCategory() {
        let base = kb(status: .duplicateOf, kind: .howTo)
        for category in [KBCategory.audiobook, .reader, .signin, .download, .library, .other] {
            XCTAssertTrue(
                base.entries(matchableFrom: category).isEmpty,
                "a duplicate_of how-to leaked into \(category)"
            )
        }
    }

    /// Control: a non-duplicate entry in the same shape IS a candidate, so the
    /// assertions above cannot pass by the builder simply producing nothing.
    func testNonDuplicateEntry_IsStillACandidate() {
        let entries = kb(status: .open, kind: nil).entries(matchableFrom: .library)
        XCTAssertEqual(entries.map(\.id), ["DUP-1"])
    }
}
