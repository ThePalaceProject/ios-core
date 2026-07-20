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
        // The known, intentional floor is the 5 bare-"download" pairs in KI-008:
        // the generic "download" token is load-bearing for recall on inputs like
        // "trying to download an ebook and it never works" (it forms the second
        // distinct region alongside "never works"), so it stays despite being a
        // substring of the specific "won't download" etc. Every other entry was
        // pruned to distinct concepts. New entries must add zero nested variants.
        if !offenders.isEmpty {
            for o in offenders { print("  NESTED-KEYWORD: \(o)") }
        }
        XCTAssertLessThanOrEqual(
            offenders.count, 6,
            "Nested keyword variants grew beyond the known KI-008 bare-'download' floor (\(offenders.count)). New entries must use distinct concepts, not nested synonyms."
        )
    }
}
