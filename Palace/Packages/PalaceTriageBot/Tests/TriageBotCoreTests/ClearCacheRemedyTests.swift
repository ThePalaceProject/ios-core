import XCTest
@testable import TriageBotCore

/// The app already ships the remedy that was missing from the middle of the set.
///
/// Settings → Advanced → "Clear Cached Data" clears the network cache and the
/// on-disk catalog/metadata/registry caches. It does NOT touch downloaded books.
/// That screen was deliberately made always-visible (PP-4788) "so support can
/// direct patrons to Send Error Logs / Data & Reset without the hidden version
/// long-press" — so support is already sending patrons there, and the bot could
/// not name the action.
///
/// This is the surgical step between reopening a title (fixes nothing
/// persistent) and reinstalling the app (destroys every download). Its absence is
/// a plausible reason support reaches for reinstall in a third of resolved
/// download tickets.
final class ClearCacheRemedyTests: XCTestCase {

    private let detector = RemedyDetector()

    /// Nothing the patron owns is lost: books stay, sign-in stays, only cached
    /// catalog data is refetched.
    func testClearingCacheIsFree() {
        XCTAssertEqual(Remedy.clearCache.costTier, .free)
    }

    /// Resetting a single library is scoped destruction — that library's content
    /// goes. Better than a full reinstall, still not free.
    func testResettingOneLibraryIsDestructive() {
        XCTAssertEqual(Remedy.resetLibrary.costTier, .destructive)
    }

    func testDetectsAPatronWhoAlreadyClearedTheCache() {
        for text in ["I cleared the cache already", "I used clear cached data in settings",
                     "cleared cached data and it did not help"] {
            XCTAssertTrue(detector.alreadyTried(in: text).contains(.clearCache),
                          "missed a clear-cache claim in: \(text)")
        }
    }

    /// The stale-registry bug is precisely what clearing cached data repairs, and
    /// the shipped entry never named it.
    func testTheStaleLibraryListEntryOffersClearingTheCache() throws {
        let kb = KnowledgeBase(catalog: try BundledCatalogSource.loadCatalogSync())
        let entry = try XCTUnwrap(kb.entry(id: "KI-2026-009-add-library-stale-registry"))
        let remedies = (entry.userFacingSteps ?? []).compactMap(\.remedy)
        XCTAssertTrue(remedies.contains(.clearCache),
                      "a stale cached library list is what clearing cached data fixes: \(remedies)")
    }
}
