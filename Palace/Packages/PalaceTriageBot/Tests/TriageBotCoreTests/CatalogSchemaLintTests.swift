import XCTest
@testable import TriageBotCore

/// Structural invariants on the bundled catalog. These are cheap guards that
/// pin the data contradictions PP-4825 fixed so they can't silently return —
/// e.g. KI-001 once carried status:open AND fixed_in_version:3.2.0, which made
/// the gate show a "fix shipping next release" card to patrons who already had
/// the fix.
final class CatalogSchemaLintTests: XCTestCase {

    private func loadEntries() throws -> [KBEntry] {
        try BundledCatalogSource.loadCatalogSync().entries
    }

    /// A fix version only makes sense on a `fixed_in` entry — that's the pair the
    /// version gate reads. Any other status carrying a fix version is the KI-001
    /// contradiction.
    func testFixVersionImpliesFixedInStatus() throws {
        for entry in try loadEntries() where entry.fixedInVersion != nil {
            XCTAssertEqual(
                entry.status, .fixedIn,
                "\(entry.id): has fixed_in_version=\(entry.fixedInVersion!) but status=\(String(describing: entry.status)). A fix version must pair with status:fixed_in or the gate misbehaves."
            )
        }
    }

    /// how_to keywords MUST be multi-word intent phrases. A bare word like
    /// "renew" fires on "renewed my card" (a live false positive we fixed) —
    /// because how_to suggests at a single distinct region, one generic word is
    /// enough to misroute. Multi-word phrases keep the single-region floor safe.
    func testHowToKeywordsAreMultiWord() throws {
        var offenders: [String] = []
        for entry in try loadEntries() where entry.resolvedKind == .howTo {
            for keyword in entry.symptomKeywords where !keyword.contains(" ") {
                offenders.append("\(entry.id): '\(keyword)'")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "how_to keywords must be multi-word intent phrases, not single words: \(offenders)")
    }

    /// Duplicate entry ids silently break `entry(id:)` lookups and telemetry.
    func testEntryIdsAreUnique() throws {
        let ids = try loadEntries().map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "catalog has duplicate entry ids")
    }

    /// how_to (general-help) entries are not bugs: no known-issue status, no fix
    /// version, no version gate. known_issue entries must carry a status.
    func testKindShapeInvariants() throws {
        for entry in try loadEntries() {
            switch entry.resolvedKind {
            case .howTo:
                XCTAssertNil(entry.status, "\(entry.id): how_to entry must not carry a known-issue status")
                XCTAssertNil(entry.fixedInVersion, "\(entry.id): how_to entry must not carry a fix version")
            case .knownIssue:
                XCTAssertNotNil(entry.status, "\(entry.id): known_issue entry must declare a status")
            }
        }
    }

    /// Distinct-region scoring made nested keyword variants within one entry dead
    /// weight (they collapse to a single region). Flagging them keeps the corpus
    /// honest about how many DISTINCT concepts an entry actually keys on.
    func testNoNestedKeywordVariantsWithinAnEntry() throws {
        var offenders: [String] = []
        for entry in try loadEntries() {
            let keywords = entry.symptomKeywords.map { TextNormalizer.normalize($0) }
            for (i, a) in keywords.enumerated() {
                for (j, b) in keywords.enumerated() where i != j {
                    // a is a strict substring of b → nested; a is redundant.
                    if a != b, b.contains(a) {
                        offenders.append("\(entry.id): '\(a)' is nested inside '\(b)'")
                    }
                }
            }
        }
        // The known, intentional set is exactly the 5 bare-"download" pairs in
        // KI-008: "download" is load-bearing for recall on inputs like "trying to
        // download an ebook and it never works" (it forms the second distinct
        // region alongside "never works"), so it stays despite being a substring
        // of the specific "won't download" etc. Every other entry was pruned to
        // distinct concepts. Asserting the exact SET (not a count ≤ N) means a
        // swap — one nesting fixed, a new one introduced — still fails.
        let allowed: Set<String> = [
            "KI-2026-008-download-no-network: 'download' is nested inside 'won't download'",
            "KI-2026-008-download-no-network: 'download' is nested inside 'wont download'",
            "KI-2026-008-download-no-network: 'download' is nested inside 'download stuck'",
            "KI-2026-008-download-no-network: 'download' is nested inside 'download failed'",
            "KI-2026-008-download-no-network: 'download' is nested inside 'stuck downloading'",
        ]
        if Set(offenders) != allowed {
            for o in offenders where !allowed.contains(o) { print("  UNEXPECTED NESTED-KEYWORD: \(o)") }
        }
        XCTAssertEqual(Set(offenders), allowed,
                       "Nested-keyword set changed. New entries must use distinct concepts, not nested synonyms; only the KI-008 bare-'download' set is grandfathered.")
    }
}
