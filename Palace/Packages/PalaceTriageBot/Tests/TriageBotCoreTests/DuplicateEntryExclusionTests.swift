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

    /// Both kinds, every category. A duplicated KNOWN ISSUE must not surface in
    /// its own category, and a duplicated HOW-TO must not surface in any of
    /// them — the widening makes how-tos candidates everywhere, so dropping the
    /// duplicate guard would be wrong six times over rather than once.
    func testDuplicateEntry_IsNeverACandidate_ForEitherKind_InAnyCategory() {
        for kind in [KBKind.howTo, nil] {
            let base = kb(status: .duplicateOf, kind: kind)
            let label = kind == .howTo ? "how-to" : "known-issue"
            for category in KBCategory.allCases {
                XCTAssertTrue(
                    base.entries(matchableFrom: category).isEmpty,
                    "a duplicate_of \(label) leaked into \(category)"
                )
            }
        }
    }

    /// Control: a non-duplicate entry in the same shape IS a candidate, so the
    /// assertions above cannot pass by the builder simply producing nothing.
    ///
    /// `lint-test-quality.py` flags this SHALLOW-001 (one assertion, few
    /// lines). Kept as-is deliberately: a control's job is to vary exactly one
    /// thing from the test it controls, and padding it with unrelated
    /// assertions would weaken that, not strengthen it. The heuristic cannot
    /// see the pairing.
    func testNonDuplicateEntry_IsStillACandidate() {
        let entries = kb(status: .open, kind: nil).entries(matchableFrom: .library)
        XCTAssertEqual(entries.map(\.id), ["DUP-1"])
    }
}
