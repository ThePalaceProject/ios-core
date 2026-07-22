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
    static let uiSurfaceChangeLog: [String: String] = [
        "settings-libraries": "2026-07-20",
        "my-books": "2026-05-01",
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
