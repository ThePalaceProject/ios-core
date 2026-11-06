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

    private func sourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent(relativePath)
    }

    /// Drops `//` comment tails so a comment that names the call does not count.
    private func code(of source: String) -> String {
        source.components(separatedBy: .newlines).map { line in
            guard let range = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<range.lowerBound])
        }.joined(separator: "\n")
    }

    private func code(at relativePath: String) throws -> String {
        code(of: try String(contentsOf: sourceURL(relativePath), encoding: .utf8))
    }

    func testEveryTransitionScreen_SignalsTheSharedCenter() throws {
        for path in Self.transitionSignallers {
            XCTAssertTrue(try code(at: path).contains(Self.transitionCall),
                          "\(path) no longer signals a screen transition, so announcements can talk over the new screen.")
        }
    }

    func testCatalog_DismissesSearchOnTabSwitchesFromTheHub() throws {
        XCTAssertTrue(try code(at: "Palace/CatalogUI/Views/CatalogView.swift")
            .contains(".onReceive(appContainer.tabRouterHub.selectionChanges)"))
    }

    /// Proves the scan can fail: a call that survives only in a comment is not
    /// a call.
    func testLint_IgnoresACallThatIsOnlyInAComment() {
        let commentedOut = """
        .onAppear {
            // appContainer.accessibilityAnnouncer.notifyScreenTransition()
        }
        """

        XCTAssertFalse(code(of: commentedOut).contains(Self.transitionCall))
    }
}
