//
//  AppTabSelectionBindingLintTests.swift
//  PalaceTests
//
//  Meta-test pinning the PP-5051 wiring contract:
//
//    BOTH `TabView(selection:)` builders in `AppTabHostView` MUST bind to
//    `tabSelection`, never to `$router.selected`.
//
//  Why this is a structural lint rather than a runtime test: the whole point of
//  `tabSelection` is that its SETTER observes a write of the CURRENT value —
//  the tap on the tab you are already on, which is the only one-tap way back to
//  a tab's root now that switching tabs preserves the stack. `$router.selected`
//  swallows that write silently. Telling the two apart needs a rendered
//  `TabView`, and PalaceTests has no SwiftUI host harness; reviewers correctly
//  observed that reverting either builder to `$router.selected` deletes the
//  gesture with every unit test still green. The options were (a) build a host
//  harness, (b) leave the wiring unpinned behind a simulator pass nobody re-runs,
//  or (c) assert the structure. This is (c) — zero production cost, and it fails
//  the moment someone re-points either builder.
//
//  Precedent for the shape: the sibling lints in this directory.
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
