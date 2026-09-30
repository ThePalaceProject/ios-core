//
//  PP-5051: both `TabView(selection:)` builders in `AppTabHostView` must bind to
//  `tabSelection`, not `$router.selected`. Its setter observes a re-tap of the
//  current tab (the one-tap way back to a tab's root); `$router.selected` drops
//  that write. Telling them apart needs a rendered TabView, which PalaceTests has
//  no host for, so this asserts the source structure instead.
//

import XCTest

final class AppTabSelectionBindingLintTests: XCTestCase {

    private var appTabHostViewPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Palace/AppInfrastructure/AppTabHostView.swift")
    }

    /// Strips `//` comment tails so the lint scans CODE, not prose — the
    /// documented `ratchet-detectors-count-comment-mentions` trap. This file's
    /// own header names `$router.selected`, and so does the source's, so without
    /// this the lint would match its own explanation.
    private func codeLines(of source: String) -> [String] {
        source.components(separatedBy: .newlines).map { line in
            guard let range = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<range.lowerBound])
        }
    }

    private func tabViewSelectionBindings() throws -> [String] {
        let source = try String(contentsOf: appTabHostViewPath, encoding: .utf8)
        return codeLines(of: source)
            .filter { $0.contains("TabView(selection:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Both builders — the iOS 18+ `Tab(value:)` one and the pre-18 `.tabItem`
    /// one — must route through `tabSelection`. The legacy builder ships:
    /// `IPHONEOS_DEPLOYMENT_TARGET` is 17.0.
    func testBothTabViewBuilders_BindToTabSelection() throws {
        let bindings = try tabViewSelectionBindings()

        XCTAssertEqual(bindings.count, 2,
                       "Expected exactly two TabView(selection:) sites — the iOS 18+ and legacy builders. Found: \(bindings)")
        for binding in bindings {
            XCTAssertTrue(binding.contains("selection: tabSelection"),
                          "Every TabView must bind to `tabSelection`, which is what makes a re-tap of the current tab observable. Found: \(binding)")
            XCTAssertFalse(binding.contains("$router.selected"),
                           "`$router.selected` swallows a write of the current value, silently deleting the return-to-root gesture. Found: \(binding)")
        }
    }

    /// Synthetic-violator self-test: proves the lint can still FAIL. Without it
    /// a refactor that breaks the scan (a renamed file, a changed call shape)
    /// turns the lint green forever and nobody notices.
    func testLint_DetectsAReversionToRouterSelected() {
        let violating = """
        private var modernTabView: some View {
            TabView(selection: $router.selected) {
        """
        let bindings = codeLines(of: violating)
            .filter { $0.contains("TabView(selection:") }

        XCTAssertEqual(bindings.count, 1, "The scan must find the violating site")
        XCTAssertTrue(bindings[0].contains("$router.selected"),
                      "The lint must be able to see a reversion — otherwise its green means nothing")
    }
}
