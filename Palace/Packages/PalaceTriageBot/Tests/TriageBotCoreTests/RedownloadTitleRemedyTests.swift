import XCTest
@testable import TriageBotCore

/// Deleting one title's downloaded copy and fetching it again is a remedy the
/// catalog already walks patrons through (KI-2026-007 step 2) — it just was not
/// tagged as one. Untagged means two things go missing: the reducer cannot skip
/// it for a patron who says they already did it, and no per-step telemetry
/// distinguishes it from any other unnamed instruction.
///
/// Tagging it is also what lets the safety rules see it at all. Until a step
/// carries a remedy, `CatalogValidator` cannot tell that it destroys anything.
final class RedownloadTitleRemedyTests: XCTestCase {

    private let detector = RemedyDetector()

    // MARK: - Cost

    /// Scoped destruction of content, classified to match `resetLibrary` rather
    /// than the free tier. The loan survives, but the deletion is irreversible
    /// from the patron's side and re-fulfilment is not guaranteed — PP-4951 is
    /// the standing reason we do not treat "the app will just fetch it again" as
    /// a promise.
    func testRedownloadIsClassifiedAsDestructiveLikeOtherScopedDeletion() {
        XCTAssertEqual(Remedy.redownloadTitle.costTier, .destructive)
        XCTAssertEqual(Remedy.resetLibrary.costTier, .destructive,
                       "the precedent this is matched to — scoped deletion is still deletion")
        XCTAssertEqual(Remedy.reopenTitle.costTier, .free,
                       "and it must not be confused with merely reopening the title")
    }

    // MARK: - Detection

    func testDetectsDeletingAndRefetchingATitle() {
        XCTAssertTrue(detector.alreadyTried(in: "I deleted the book and downloaded it again, same thing")
            .contains(.redownloadTitle))
        XCTAssertTrue(detector.alreadyTried(in: "I removed the title and re-downloaded it")
            .contains(.redownloadTitle))
    }

    /// The collision that makes this remedy risky to add. "I have uninstalled
    /// and redownloaded several times" is verbatim corpus wording about the APP,
    /// and it is already claimed by `reinstall`. If a bare "redownloaded" phrase
    /// were added here, that patron would have the reinstall step skipped for
    /// them on the strength of a title-level claim they never made.
    func testAppReinstallWordingIsNotMistakenForATitleRedownload() {
        let tried = detector.alreadyTried(in: "I have uninstalled and redownloaded several times")
        XCTAssertTrue(tried.contains(.reinstall), "this is still an app reinstall")
        XCTAssertFalse(tried.contains(.redownloadTitle),
                       "reinstalling the app says nothing about deleting an individual title")
    }

    /// Same conservatism as every other remedy: asking about it is not doing it.
    func testAskingAboutItIsNotHavingDoneIt() {
        XCTAssertFalse(detector.alreadyTried(in: "should I delete the book and download it again?")
            .contains(.redownloadTitle))
    }

    // MARK: - The catalog has to use it

    /// The step whose existence motivated the remedy. Without this the tag is
    /// implemented and unused, which is the same inert-mechanism failure as a
    /// version gate shipped with no version authored.
    func testTheDeleteAndRedownloadStepIsTagged() throws {
        let catalog = try BundledCatalogSource.loadCatalogSync()
        let step = catalog.entries
            .first { $0.id.hasPrefix("KI-2026-007") }?
            .userFacingSteps?
            .first { $0.id.contains("delete-and-redownload") }
        XCTAssertEqual(step?.remedy, .redownloadTitle,
                       "the step that tells patrons to delete and re-fetch must say so")
    }

    /// Tagging it destructive puts it under the safety rules, so the bundled
    /// catalog has to keep satisfying them — never first, always refusable.
    func testTaggingItKeepsTheBundledCatalogValid() throws {
        let catalog = try BundledCatalogSource.loadCatalogSync()
        XCTAssertEqual(CatalogValidator.violations(in: catalog), [])
    }

    /// A destructive step must leave the patron a way out. `notApplicable`
    /// advances just as `advance` does, so it counts as an escape — the
    /// validator learning about the new outcome is part of this change.
    func testNotApplicableCountsAsARefusalRoute() {
        let entry = KBEntry(
            id: "GF-x", category: .other, kind: .genericFlow,
            symptomKeywords: [],
            userFacingWorkaround: "…",
            userFacingSteps: [
                KBStep(id: "a", instruction: "Something free.", check: "?", remedy: .reopenTitle),
                KBStep(id: "b", instruction: "Delete and fetch it again.", check: "?",
                       responses: [
                           .init(label: "Still broken", outcome: .notApplicable),
                           .init(label: "Fixed", outcome: .resolved),
                       ],
                       remedy: .redownloadTitle),
            ],
            confidenceThreshold: 0.1)
        let catalog = KBCatalog(version: "t", updatedAt: "x", entries: [entry])
        XCTAssertEqual(CatalogValidator.violations(in: catalog), [],
                       "notApplicable advances, so the patron is not trapped on a destructive step")
    }
}
