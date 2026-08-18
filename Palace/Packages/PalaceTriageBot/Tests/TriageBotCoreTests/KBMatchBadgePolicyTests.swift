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

    /// Known-issue statuses are untouched by the change.
    func testKnownIssueStatuses_AreUnchanged() throws {
        let entries = try catalog().entries
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
