import XCTest
@testable import TriageBotCore

/// PP-4831 — governance for the general-help (how_to) lane. A how_to answer names
/// UI ("go to Settings → Libraries") and has no fix version to expire against, so
/// it goes stale silently when the app's navigation moves. This pins that every
/// how_to entry is anchored to a UI surface + carries a review date, and flags any
/// answer that was last reviewed BEFORE its surface changed — i.e. the screen moved
/// and nobody re-checked the directions.
final class HowToGovernanceTests: XCTestCase {

    /// The UI-surface change log. Bump a surface's date whenever its screen/nav
    /// changes; any how_to reviewed before that date then fails the staleness check
    /// until a human re-verifies the answer and bumps its `reviewed_at`.
    ///
    /// `settings-libraries` last changed 2026-07-20 — the Palace-icon library
    /// switcher moved into Settings (PP-4825). The switch/add-library answers were
    /// re-reviewed the same day, so they pass; had they not been, this would fail.
    ///
    /// `holds` and `my-books` both last changed **2026-09-02**: `ed8361a2d`
    /// (PP-5066, #1447) removed the Palace-icon library-switch affordance from
    /// `HoldsView.swift` and `MyBooksView.swift`. An earlier draft of this entry
    /// said 2026-07-10 — `76a3586e0`, the empty-state icon removal — which was
    /// the right commit when the draft was written and was overtaken while it
    /// sat unlanded. `my-books` had been logged as 2026-05-01, understating it
    /// twice over; `holds` was absent entirely and so was never staleness-checked
    /// at all.
    ///
    /// Moving to 2026-09-02 flags all five answers on those two surfaces, which
    /// is the point of the log. Each was then read against that specific change:
    /// `ed8361a2d` removed a library switcher, and none of the five mentions a
    /// library switcher or any affordance it touched. They give these
    /// instructions — return via My Books swipe-left (HT-2026-002), open the
    /// title from your holds (HT-2026-005), and no UI navigation at all
    /// (HT-2026-006, -007, -009). Their `reviewed_at` moved to 2026-09-28 on the
    /// strength of that reading and nothing more; it is not a claim that the
    /// wording was re-edited.
    ///
    /// `settings-libraries` is NOT affected: `ed8361a2d` touches four files and
    /// none of them is a settings screen.
    static let uiSurfaceChangeLog: [String: String] = [
        "settings-libraries": "2026-07-20",
        "my-books": "2026-09-02",
        "holds": "2026-09-02",
        "catalog": "2026-05-01",
        "notifications-settings": "2026-07-20",
    ]

    private func loadEntries() throws -> [KBEntry] {
        try BundledCatalogSource.loadCatalogSync().entries
    }

    /// Entries whose answer was last reviewed before their anchored surface changed.
    /// ISO dates compare correctly as strings. Shared by the catalog test and the
    /// teeth test so both exercise the same logic.
    static func staleHowToEntries(_ entries: [KBEntry], changeLog: [String: String]) -> [String] {
        var stale: [String] = []
        for entry in entries where entry.resolvedKind == .howTo {
            guard let surface = entry.uiSurface,
                  let reviewed = entry.reviewedAt,
                  let changed = changeLog[surface] else { continue }
            if reviewed < changed {
                stale.append("\(entry.id): reviewed \(reviewed) < surface '\(surface)' changed \(changed)")
            }
        }
        return stale
    }

    // MARK: - Structure: every how_to is anchored + dated + known

    func testEveryHowTo_isAnchoredAndDated() throws {
        for entry in try loadEntries() where entry.resolvedKind == .howTo {
            XCTAssertNotNil(entry.uiSurface, "\(entry.id): how_to must declare a ui_surface it depends on")
            XCTAssertNotNil(entry.reviewedAt, "\(entry.id): how_to must carry a reviewed_at date")
        }
    }

    func testEveryHowToSurface_isInTheChangeLog() throws {
        for entry in try loadEntries() where entry.resolvedKind == .howTo {
            guard let surface = entry.uiSurface else { continue }
            XCTAssertNotNil(Self.uiSurfaceChangeLog[surface],
                            "\(entry.id): ui_surface '\(surface)' is not a known UI surface. Add it to the change log (and remove a surface that no longer exists).")
        }
    }

    // MARK: - Drift: no how_to reviewed before its surface changed

    func testNoHowTo_wasReviewedBeforeItsSurfaceChanged() throws {
        let stale = Self.staleHowToEntries(try loadEntries(), changeLog: Self.uiSurfaceChangeLog)
        XCTAssertTrue(stale.isEmpty,
                      "how_to answers whose screen changed after they were last reviewed — re-verify the directions and bump reviewed_at:\n  \(stale.joined(separator: "\n  "))")
    }

    // MARK: - The lint has teeth

    func testStalenessLint_catchesADriftedEntry() {
        // A how_to reviewed in January, anchored to a surface that changed in July,
        // MUST be flagged — proof the check would fire when the UI moves under an
        // un-re-reviewed answer.
        let drifted = KBEntry(
            id: "HT-STALE", category: .library, kind: .howTo,
            symptomKeywords: ["switch library"],
            userFacingWorkaround: "Tap the (now-removed) top-left logo to switch libraries.",
            confidenceThreshold: 0.1, uiSurface: "settings-libraries", reviewedAt: "2026-01-01"
        )
        let stale = Self.staleHowToEntries([drifted], changeLog: Self.uiSurfaceChangeLog)
        XCTAssertEqual(stale.count, 1, "a Jan-reviewed answer on a July-changed surface must be flagged")
    }

    func testFreshlyReviewedEntry_isNotFlagged() {
        let fresh = KBEntry(
            id: "HT-FRESH", category: .library, kind: .howTo,
            symptomKeywords: ["switch library"],
            userFacingWorkaround: "Go to Settings → Libraries and tap the one you want.",
            confidenceThreshold: 0.1, uiSurface: "settings-libraries", reviewedAt: "2026-07-20"
        )
        XCTAssertTrue(Self.staleHowToEntries([fresh], changeLog: Self.uiSurfaceChangeLog).isEmpty)
    }
}
