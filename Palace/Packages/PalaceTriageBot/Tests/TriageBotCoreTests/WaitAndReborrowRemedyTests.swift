import XCTest
@testable import TriageBotCore

/// Two remedies the corpus argued for.
///
/// `waitForFix` is the largest single resolution class in 212 resolved tickets —
/// 44 of them, more than any actual repair. Support's answer to one patron in
/// five is "we know, it is fixed in a release that is coming." The bot could not
/// say that at all, so it walked those patrons through refreshes instead, which
/// is worse than saying nothing.
///
/// `returnAndReborrow` is rare in the corpus (2 of 212) but addresses a failure
/// mode nothing else touches: one bad loan or fulfilment rather than a bad app
/// state. Support reached for it when they could play a title themselves that
/// the patron could not.
final class WaitAndReborrowRemedyTests: XCTestCase {

    private let detector = RemedyDetector()

    // MARK: - Cost

    /// Returning a title to fix it is not free and not merely disruptive. If a
    /// hold queue has formed, giving the loan back can cost the patron their
    /// place in line, which they cannot undo — a smaller blast radius than
    /// reinstalling, but the same kind of loss.
    func testReturnAndReborrowIsDestructive() {
        XCTAssertEqual(Remedy.returnAndReborrow.costTier, .destructive)
    }

    /// Being told a fix is coming costs nothing.
    func testWaitForFixIsFree() {
        XCTAssertEqual(Remedy.waitForFix.costTier, .free)
    }

    // MARK: - Detection

    func testDetectsAPatronWhoAlreadyReturnedAndReborrowed() {
        for text in ["I returned it and checked it back out",
                     "I gave the book back and borrowed it again",
                     "returned and re-borrowed the audiobook, same thing"] {
            XCTAssertTrue(detector.alreadyTried(in: text).contains(.returnAndReborrow),
                          "missed a return-and-reborrow claim in: \(text)")
        }
    }

    /// "I am waiting for the fix" is a patron telling us they already know. It
    /// should not be re-offered as news.
    func testDetectsAPatronAlreadyWaitingOnAFix() {
        XCTAssertTrue(detector.alreadyTried(in: "I was told this is fixed in the next update, still waiting")
                        .contains(.waitForFix))
    }

    /// Borrowing something for the first time is not returning it.
    func testBorrowingIsNotReturning() {
        XCTAssertFalse(detector.alreadyTried(in: "I borrowed a book yesterday and it will not open")
                        .contains(.returnAndReborrow))
    }

    // MARK: - Where it may be said

    /// A generic ladder fires when NOTHING matched. Telling that patron a fix is
    /// coming would be an invention — we do not know what their problem is, so we
    /// cannot know a fix exists for it. It may only appear on an entry that
    /// documents a real defect.
    func testWaitForFixIsRejectedInAGenericLadder() {
        let ladder = KBEntry(
            id: "GF-audiobook", category: .audiobook, kind: .genericFlow,
            symptomKeywords: [], userFacingWorkaround: "Try things.",
            userFacingSteps: [KBStep(id: "g1", instruction: "Sit tight.", check: "OK?", remedy: .waitForFix)])
        XCTAssertFalse(
            CatalogValidator.violations(in: KBCatalog(version: "t", updatedAt: "x", entries: [ladder])).isEmpty,
            "we cannot promise a fix for a problem we did not identify")
    }

    /// On a known issue it is exactly the right thing to say.
    func testWaitForFixIsAllowedOnAKnownIssue() {
        let known = KBEntry(
            id: "KI-REAL", category: .audiobook, status: .open,
            symptomKeywords: ["will not play"],
            userFacingWorkaround: "A fix is on the way.",
            userFacingSteps: [KBStep(id: "s1", instruction: "A fix is in the next release.",
                                     check: "Would you like support to follow up?", remedy: .waitForFix)])
        XCTAssertEqual(
            CatalogValidator.violations(in: KBCatalog(version: "t", updatedAt: "x", entries: [known])), [])
    }
}
