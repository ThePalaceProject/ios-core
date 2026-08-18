import XCTest
@testable import TriageBotCore

/// The badge is the one line telling a patron how much to trust the card under
/// it, so "we did not recognise this, here are some general checks" must not be
/// dressed as "here is the answer".
final class KBMatchBadgePolicyTests: XCTestCase {

    private func catalog() throws -> KBCatalog { try BundledCatalogSource.loadCatalogSync() }

    /// The defect. Every shipped generic ladder previously badged "How to"
    /// because it has no `status` and the badge switched on status alone.
    func testEveryGenericLadderInTheShippedCatalog_IsNotBadgedAsAHowTo() throws {
        let ladders = try catalog().entries.filter { $0.resolvedKind == .genericFlow }
        XCTAssertFalse(ladders.isEmpty, "catalog has no generic ladders — this test would be vacuous")

        for ladder in ladders {
            XCTAssertEqual(
                KBMatchBadgePolicy.badge(for: ladder), .narrowingDown,
                "\(ladder.id) is a generic troubleshooting ladder, not an answer"
            )
        }
    }

    /// The other side of the same distinction: real how-tos keep their badge.
    func testEveryHowToInTheShippedCatalog_IsStillBadgedAsAHowTo() throws {
        let howTos = try catalog().entries.filter { $0.resolvedKind == .howTo }
        XCTAssertFalse(howTos.isEmpty)

        for howTo in howTos {
            XCTAssertEqual(KBMatchBadgePolicy.badge(for: howTo), .howTo, "\(howTo.id)")
        }
    }

    /// Kind is checked BEFORE status, and this pins why: status cannot tell the
    /// two apart, because a ladder and a how-to both carry none. If someone
    /// reorders the policy to switch on status first, this fails.
    func testLadderAndHowTo_AreIndistinguishableByStatusAlone() throws {
        let entries = try catalog().entries
        let ladder = try XCTUnwrap(entries.first { $0.resolvedKind == .genericFlow })
        let howTo = try XCTUnwrap(entries.first { $0.resolvedKind == .howTo })

        XCTAssertNil(ladder.status)
        XCTAssertNil(howTo.status)
        XCTAssertNotEqual(
            KBMatchBadgePolicy.badge(for: ladder), KBMatchBadgePolicy.badge(for: howTo),
            "the policy must separate them on kind, since status cannot"
        )
    }

    /// Two badge branches the shipped catalog cannot reach, so a catalog walk
    /// asserts nothing about them and their mutants survive:
    ///   - `.knownIssueFixComing` needs `open` WITH a `fixed_in_version`; every
    ///     shipped `open` entry has none.
    ///   - the `"next release"` fallback needs `fixed_in` WITHOUT a version;
    ///     every shipped `fixed_in` entry has one.
    /// Raised by SoD review, and the same synthetic-entry technique this file
    /// already uses for the unshipped statuses — it was just applied
    /// inconsistently.
    func testBadgeBranchesTheShippedCatalogCannotReach() {
        let fixComing = KBEntry(
            id: "SYNTH-open-with-version", category: .library, status: .open,
            fixedInVersion: "9.9.9", symptomKeywords: ["x"],
            userFacingWorkaround: "...", confidenceThreshold: 0.1
        )
        XCTAssertEqual(
            KBMatchBadgePolicy.badge(for: fixComing),
            .knownIssueFixComing(version: "9.9.9"),
            "an open issue WITH a fix version must promise the fix, not just a workaround"
        )

        let fixedNoVersion = KBEntry(
            id: "SYNTH-fixed-no-version", category: .library, status: .fixedIn,
            symptomKeywords: ["x"], userFacingWorkaround: "...", confidenceThreshold: 0.1
        )
        XCTAssertEqual(
            KBMatchBadgePolicy.badge(for: fixedNoVersion),
            .fixedIn(version: "next release"),
            "a fixed entry with no version must fall back, not render an empty version"
        )
    }

    /// The label table as-built section 3.6 publishes as PORT CONTRACT. Pinned
    /// here because the doc is authoritative and a table no test pins is a table
    /// the Kotlin port can silently diverge from. The strings moved into Core
    /// for exactly this reason — in `TriageBotUI` they were unreachable by
    /// macOS `swift test`.
    func testBadgeLabels_MatchThePublishedPortContract() {
        let expected: [(KBMatchBadge, String)] = [
            (.fixedIn(version: "3.2.4"), "Fixed in 3.2.4"),
            (.knownIssueFixComing(version: "3.3.0"), "Known issue — fix coming in 3.3.0"),
            (.knownIssueWorkaround, "Known issue — workaround available"),
            (.setupMixUp, "Likely a setup mix-up"),
            (.byDesign, "By design"),
            (.tracked, "Tracked"),
            (.howTo, "How to"),
            (.narrowingDown, "Let's narrow it down"),
        ]
        for (badge, label) in expected {
            XCTAssertEqual(badge.label, label)
        }
        // The distinction the whole change exists to make.
        XCTAssertNotEqual(KBMatchBadge.narrowingDown.label, KBMatchBadge.howTo.label)
    }

    /// The three statuses no shipped entry uses. `testKnownIssueStatuses_…`
    /// below walks the real catalog, so its `default: break` silently skips
    /// these — they had no coverage at all. Synthetic entries reach them.
    func testStatusesWithNoShippedEntry_StillMapToTheirOwnBadge() {
        let expected: [(KBStatus, KBMatchBadge)] = [
            (.userError, .setupMixUp),
            (.wontfix, .byDesign),
            (.duplicateOf, .tracked),
        ]
        for (status, badge) in expected {
            let entry = KBEntry(
                id: "SYNTH-\(status.rawValue)",
                category: .library,
                status: status,
                symptomKeywords: ["x"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.1
            )
            XCTAssertEqual(KBMatchBadgePolicy.badge(for: entry), badge, "status \(status.rawValue)")
        }
    }

    /// Known-issue statuses are untouched by the change.
    func testKnownIssueStatuses_AreUnchanged() throws {
        let entries = try catalog().entries
        // Vacuity guard, matching this file's other catalog walks: a filter that
        // matched nothing would make every assertion below unreachable and the
        // test would still pass.
        XCTAssertFalse(
            entries.filter { $0.resolvedKind == .knownIssue }.isEmpty,
            "no known-issue entries — this walk asserts nothing"
        )
        for entry in entries where entry.resolvedKind == .knownIssue {
            let badge = KBMatchBadgePolicy.badge(for: entry)
            switch entry.status {
            case .open where entry.fixedInVersion == nil:
                XCTAssertEqual(badge, .knownIssueWorkaround, "\(entry.id)")
            case .open:
                XCTAssertEqual(badge, .knownIssueFixComing(version: entry.fixedInVersion!), "\(entry.id)")
            case .fixedIn:
                XCTAssertEqual(badge, .fixedIn(version: entry.fixedInVersion ?? "next release"), "\(entry.id)")
            default:
                break
            }
        }
    }
}
