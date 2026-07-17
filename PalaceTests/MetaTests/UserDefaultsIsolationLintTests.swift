import XCTest

/// Warn-only lint: discourages `UserDefaults.standard` outside the
/// whitelisted files in `PalaceTests/**`. Surfaces violations via
/// `XCTContext.runActivity` so the test report carries the evidence
/// but the test itself does NOT fail.
///
/// The rationale matches `swarm_47883816/contracts/D-UserDefaultsIsolation.md`:
/// existing tests interact with production code that reads
/// `UserDefaults.standard` directly (`AccountsManager`, `CatalogRepository`,
/// `TPPBookmarkDeletionLog`, etc.) — migrating those tests requires
/// adding DI to those production classes, which is out of D's scope.
/// We document the violators here so the future "production DI sweep"
/// pass has a runnable inventory.
///
/// Strict mode is implemented as a separate self-test
/// (`testLintCatchesSyntheticViolatorIfStrictModeEnabled`) so the
/// detector logic itself is covered without affecting the warn-only
/// posture for the real codebase.
@MainActor
final class UserDefaultsIsolationLintTests: XCTestCase {

    /// Files that are allowed to reference `UserDefaults.standard`
    /// directly. Maintained alongside the migration: when a follow-up
    /// adds DI to a production class and the test no longer needs the
    /// pollution path, remove the file from this list.
    private static let whitelist: Set<String> = [
        // The helper itself. It explicitly calls
        // `UserDefaults.standard.removePersistentDomain(forName:)` to
        // clear its own suite.
        "Support/XCTestCase+testUserDefaults.swift",

        // swarm_cd181acd D-cleanup landed DI seams on AccountDetails,
        // AccountsManager, TPPBookmarkDeletionLog, CatalogRepository,
        // and TPPSignInBusinessLogic+ForceReset; the eight previously
        // deferred test files now use `testUserDefaults()` and have
        // been removed from this whitelist. Future test files that
        // reach into `.standard` will trip the warn-only lint and the
        // author can either migrate (the seam exists now) or add a
        // justified entry here.

        // The lint test itself references the string literally in
        // assertion bodies — that's a self-reference, not a violation.
        "MetaTests/UserDefaultsIsolationLintTests.swift",
    ]

    /// PalaceTests directory root, resolved at runtime by walking up
    /// from this file to the `PalaceTests/` ancestor. Tests must be
    /// resilient to running under either the worktree or the main
    /// checkout.
    private static var palaceTestsRoot: URL? {
        var url = URL(fileURLWithPath: #file)
        // Walk up until we find a directory whose lastPathComponent is
        // "PalaceTests".
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "PalaceTests" {
                return url
            }
        }
        return nil
    }

    // MARK: - Warn-only lint over PalaceTests/**

    /// Walks `PalaceTests/**/*.swift` and emits a warning attachment
    /// for any file that references `UserDefaults.standard` outside
    /// the whitelist. Does NOT XCTFail — the lint is warn-only until
    /// the follow-up production DI sweep lands.
    func testWarnsOnUserDefaultsStandardOutsideWhitelist() {
        guard let root = Self.palaceTestsRoot else {
            // Best-effort — if we can't locate PalaceTests/ the lint
            // skips. The helper test
            // (`testLintCatchesSyntheticViolatorIfStrictModeEnabled`)
            // covers the detector logic on synthetic input.
            return
        }

        let violators = Self.scanForViolators(under: root)

        for (relativePath, lineCount) in violators {
            XCTContext.runActivity(named: "UserDefaults.standard violator: \(relativePath)") { activity in
                let payload = """
                File: \(relativePath)
                UserDefaults.standard references: \(lineCount)
                Action: migrate to testUserDefaults() once the production class \
                under test exposes a UserDefaults DI seam. Until then this file \
                is documented as a deferred gap in \
                .forgeos/swarms/swarm_47883816/D-deferred-production-DI.md.
                """
                activity.add(XCTAttachment(string: payload))
            }
        }

        // Sanity attachment so the test report carries a top-line
        // count even when no violators exist.
        XCTContext.runActivity(named: "UserDefaultsIsolationLint summary") { activity in
            activity.add(XCTAttachment(string: "Violator files: \(violators.count)"))
        }
    }

    // MARK: - Self-test for detector logic

    /// Proves the detector actually catches the pattern by running it
    /// on a synthetic in-memory input. This keeps the detector itself
    /// covered without forcing warn-only mode to become strict.
    func testLintCatchesSyntheticViolatorIfStrictModeEnabled() {
        let cleanInput = """
        import XCTest
        @MainActor
        final class CleanTests: XCTestCase {
            func test_doesNotMentionTheBannedString() {
                let defaults = testUserDefaults()
                defaults.set(true, forKey: "ok")
            }
        }
        """
        XCTAssertFalse(
            Self.contentHasUserDefaultsStandard(cleanInput),
            "Clean input must not match the detector"
        )

        let dirtyInput = """
        import XCTest
        @MainActor
        final class DirtyTests: XCTestCase {
            func test_usesStandard() {
                UserDefaults.standard.set(true, forKey: "bad")
            }
        }
        """
        XCTAssertTrue(
            Self.contentHasUserDefaultsStandard(dirtyInput),
            "Dirty input must match the detector — otherwise the lint sees nothing"
        )

        // Edge case: a string literal that happens to contain the
        // banned token but is wrapped in a comment is still flagged.
        // The detector is intentionally regex-grep-flavoured (matches
        // CLAUDE.md's `grep -rn 'UserDefaults.standard'` invariant)
        // rather than AST-aware — we want false positives over
        // silent misses.
        let commentedInput = """
        // Pre-existing comment referencing UserDefaults.standard.
        """
        XCTAssertTrue(
            Self.contentHasUserDefaultsStandard(commentedInput),
            "Comments also count — keeps the detector matching the grep contract"
        )
    }

    // MARK: - Detector primitives

    /// Returns the relative path (from `PalaceTests/`) of every file
    /// under `root` that contains `UserDefaults.standard` AND is not
    /// in the whitelist, paired with the number of matching lines.
    private static func scanForViolators(under root: URL) -> [(relativePath: String, lineCount: Int)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(String, Int)] = []
        let rootPath = root.path

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let path = fileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            if whitelist.contains(relative) { continue }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lineCount = content.split(separator: "\n").reduce(0) { acc, line in
                line.contains("UserDefaults.standard") ? acc + 1 : acc
            }
            if lineCount > 0 {
                results.append((relative, lineCount))
            }
        }

        return results.sorted { $0.0 < $1.0 }
    }

    /// Pure substring detector, broken out so the self-test can hit
    /// it directly without filesystem I/O.
    private static func contentHasUserDefaultsStandard(_ content: String) -> Bool {
        return content.contains("UserDefaults.standard")
    }
}
