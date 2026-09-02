//
//  LibraryIconInertLintTests.swift
//  PalaceTests
//
//  PP-5066 — the guard PP-4821 needed and did not have.
//

import XCTest

/// PP-4821 decided the Palace icon is static branding: library switching lives
/// solely in Settings. It was applied by editing `CatalogView` — one of the
/// three screens that render the icon. `MyBooksView` and `HoldsView` kept a
/// working `Button` + action sheet, so the removed behaviour stayed reachable
/// on two of three screens, and VoiceOver announced "Switch Library" on exactly
/// the two screens it had been removed from. It shipped that way for over a
/// month and was found by hand during the 3.3.0 release regression.
///
/// A passing suite could not have caught that: nothing was broken, a screen
/// simply kept an affordance it was supposed to lose. This is the shape the
/// project's own rule names — *a behaviour change to a shared element needs a
/// call-site census, not just a green suite* — so the census is mechanical here
/// rather than a thing someone has to remember.
///
/// The lint scans `Palace/` for every use of the icon and asserts each one is
/// inert. It deliberately reads the production tree, not the test tree: the
/// defect lives at the call sites, and no diff-scoped check can find a call
/// site that a change forgot to visit.
@MainActor
final class LibraryIconInertLintTests: XCTestCase {

    /// `Palace/` resolved relative to this file, so the lint works in any
    /// checkout — no env vars, no CI-specific paths.
    private static let palaceSourceRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MetaTests/
            .deletingLastPathComponent()   // PalaceTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Palace")
    }()

    private static let iconToken = "myLibraryIcon"

    /// Markers that mean the icon is an interactive control rather than
    /// branding. Each is checked in the lines immediately around the icon so a
    /// `Button` elsewhere in a large view file cannot produce a false positive.
    private static let interactiveMarkers = [
        "contentShape(",          // only added to make a tap target
        "accessibilityLabel(",    // branding carries no label; it is hidden
        "accessibilityIdentifier(" // a driven control; branding is not driven
    ]

    func testPalaceIconIsBrandingOnlyEverywhereItIsUsed() throws {
        let files = try swiftFiles(under: Self.palaceSourceRoot)
        XCTAssertFalse(files.isEmpty, "resolved no Swift files under \(Self.palaceSourceRoot.path)")

        var offenders: [String] = []
        var sitesChecked = 0

        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(Self.iconToken) else { continue }

            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(Self.iconToken) {
                sitesChecked += 1
                let rel = url.path.replacingOccurrences(of: Self.palaceSourceRoot.path + "/", with: "")

                // A Button construct in the few lines above — `Button {` or
                // `Button(action:`. Matching the construct, not the word, so a
                // property named `leadingBarButton` does not trip it.
                let above = lines[max(0, index - 8)..<index]
                if above.contains(where: {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return t.hasPrefix("Button {") || t.hasPrefix("Button(") || t.contains("Button(action:")
                }) {
                    offenders.append("\(rel):\(index + 1) — icon is inside a Button construct")
                }

                let below = lines[index..<min(lines.count, index + 6)]
                for marker in Self.interactiveMarkers where below.contains(where: { $0.contains(marker) }) {
                    offenders.append("\(rel):\(index + 1) — icon carries `\(marker)`, which only an interactive control needs")
                }

                if !below.contains(where: { $0.contains("accessibilityHidden(true)") }) {
                    offenders.append("\(rel):\(index + 1) — icon is not `accessibilityHidden(true)`; branding must not reach VoiceOver")
                }
            }
        }

        XCTAssertGreaterThan(sitesChecked, 0,
                             "found no `\(Self.iconToken)` sites — the lint has stopped scanning anything and would pass vacuously")

        XCTAssertTrue(offenders.isEmpty, """
            The Palace icon must be branding only (PP-4821, re-broken and re-fixed as PP-5066).
            Library switching lives solely in Settings. \(sitesChecked) site(s) scanned:

            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: - Helpers

    private func swiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            files.append(url)
        }
        return files
    }
}
