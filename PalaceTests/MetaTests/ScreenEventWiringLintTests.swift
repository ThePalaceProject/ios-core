//
//  PP-5473: screens tell the app's announcement center about transitions, and
//  the catalog learns about tab switches from the tab router hub. Both are
//  calls inside SwiftUI `onAppear`/`onReceive`, which PalaceTests has no host to
//  render, so this asserts the source structure instead.
//

import XCTest

final class ScreenEventWiringLintTests: XCTestCase {

    private static let transitionCall = "accessibilityAnnouncer.notifyScreenTransition()"

    /// Every screen that signals a transition. NavigationHostView signals for
    /// the audiobook toolkit's player, which cannot reach the app's center.
    private static let transitionSignallers = [
        "Palace/Book/UI/BookDetail/BookDetailView.swift",
        "Palace/Book/UI/BookDetail/HalfSheetview.swift",
        "Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift",
        "Palace/AppInfrastructure/NavigationHostView.swift"
    ]

    /// Comments are blanked so a commented-out call does not count.
    private func code(at relativePath: String) throws -> String {
        let url = LintSourceText.repoRoot.appendingPathComponent(relativePath)
        return LintSourceText.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    func testEveryTransitionScreen_SignalsTheSharedCenter() throws {
        for path in Self.transitionSignallers {
            XCTAssertTrue(try code(at: path).contains(Self.transitionCall),
                          "\(path) no longer signals a screen transition, so announcements can talk over the new screen.")
        }
    }

    func testCatalog_DismissesSearchOnTabSwitchesFromTheHub() throws {
        XCTAssertTrue(try code(at: "Palace/CatalogUI/Views/CatalogView.swift")
            .contains(".onReceive(appContainer.tabRouterHub.selectionChanges)"),
                      "CatalogView no longer dismisses an open search when the patron switches tabs.")
    }

    /// Proves the scan can fail: a call that survives only in a comment is not
    /// a call.
    func testLint_IgnoresACallThatIsOnlyInAComment() {
        let commentedOut = """
        .onAppear {
            // appContainer.accessibilityAnnouncer.notifyScreenTransition()
            /* appContainer.accessibilityAnnouncer.notifyScreenTransition() */
        }
        """

        XCTAssertFalse(LintSourceText.strippingComments(commentedOut).contains(Self.transitionCall))
    }
}
