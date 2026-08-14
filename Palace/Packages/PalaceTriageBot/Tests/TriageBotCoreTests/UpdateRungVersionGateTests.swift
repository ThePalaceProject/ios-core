import XCTest
@testable import TriageBotCore

/// "Update the app" is the most-prescribed remedy in the corpus (20% of
/// resolutions) and the first rung of several ladders. It is also the one rung
/// the bot can be demonstrably wrong about: a patron already on the newest build
/// is sent to the App Store to find nothing, which reads as the bot not knowing
/// the state of their own device.
///
/// The catalog can carry the newest version it knows of, and the ladder skips
/// the rung for anyone already at or past it. Deliberately conservative in both
/// unknown cases — no context, or no declared version — because a wasted rung
/// costs seconds while a suppressed one may cost the fix. Worst case the field
/// goes stale and one cohort sees a rung they do not need, which is the same
/// cost as not having the gate at all.
final class UpdateRungVersionGateTests: XCTestCase {

    private func kb(latestKnown: String?) -> KnowledgeBase {
        let ladder = KBEntry(
            id: "GF-audiobook", category: .audiobook, kind: .genericFlow,
            symptomKeywords: [],
            userFacingWorkaround: "A few things to try.",
            userFacingSteps: [
                KBStep(id: "g1", instruction: "Check the App Store.", check: "Updated?", remedy: .updateApp),
                KBStep(id: "g2", instruction: "Tap the title again.", check: "Playing?", remedy: .reopenTitle),
            ])
        return KnowledgeBase(catalog: KBCatalog(
            version: "t", updatedAt: "x", entries: [ladder], latestKnownAppVersion: latestKnown))
    }

    private func firstRung(latestKnown: String?, appVersion: String?) -> Int? {
        let r = ConversationReducer(knowledgeBase: kb(latestKnown: latestKnown))
        var (s, _) = r.reduce(state: ConversationState(), action: .start)
        if let appVersion {
            (s, _) = r.reduce(state: s, action: .contextLoaded(
                ContextSnapshot(appVersion: appVersion, appBuild: "1", osVersion: "26.0", deviceModel: "iPhone")))
        }
        (s, _) = r.reduce(state: s, action: .userTappedCategory(.audiobook))
        (s, _) = r.reduce(state: s, action: .inputChanged("something is wrong"))
        (s, _) = r.reduce(state: s, action: .userSubmittedDescription)
        (s, _) = r.reduce(state: s, action: .userTappedStartGuidedFlow(entryId: "GF-audiobook"))
        if case .guidedStep(_, let index, _, _) = s.step { return index }
        return nil
    }

    func testUpdateRung_isSkippedWhenAlreadyOnTheNewestKnownVersion() {
        XCTAssertEqual(firstRung(latestKnown: "3.2.3", appVersion: "3.2.3"), 1,
                       "sending someone already current to the App Store finds nothing")
    }

    func testUpdateRung_isSkippedWhenAheadOfTheNewestKnownVersion() {
        XCTAssertEqual(firstRung(latestKnown: "3.2.3", appVersion: "3.3.0"), 1,
                       "a stale catalog must not re-offer an update to a newer build")
    }

    func testUpdateRung_isOfferedWhenBehind() {
        XCTAssertEqual(firstRung(latestKnown: "3.2.3", appVersion: "3.2.1"), 0)
    }

    func testUpdateRung_isOfferedWhenTheCatalogDeclaresNoLatestVersion() {
        XCTAssertEqual(firstRung(latestKnown: nil, appVersion: "3.2.3"), 0,
                       "unknown must not suppress — a wasted rung beats a withheld fix")
    }

    func testUpdateRung_isOfferedWhenTheAppVersionIsUnknown() {
        XCTAssertEqual(firstRung(latestKnown: "3.2.3", appVersion: nil), 0)
    }
}

extension UpdateRungVersionGateTests {

    /// The gate is only real if the SHIPPED catalog arms it. It was built, tested
    /// against fixture catalogs, and shipped inert — `latest_known_app_version`
    /// was never authored, so every ladder offered "check for an update" to
    /// patrons already on the newest build. Tested machinery with unauthored data
    /// is indistinguishable from no machinery.
    func testShippedCatalog_ArmsTheVersionGate() throws {
        let catalog = try BundledCatalogSource.loadCatalogSync()
        let declared = try XCTUnwrap(catalog.latestKnownAppVersion,
            "the shipped catalog declares no newest-known version, so the update rung never skips")
        XCTAssertNotNil(SemanticVersion(declared), "must parse as a version: \(declared)")
    }
}
