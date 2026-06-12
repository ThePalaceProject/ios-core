//
//  RuntimeQuiescenceLintTests.swift
//  PalaceTests
//
//  The STRUCTURAL half of the WS-0 / M0 runtime-quiescence gate. The
//  `PalaceTestCase.tearDownWithError` assert is the RUNTIME enforcement, but it
//  is opt-in — it only protects tests that subclass the quiescence base. This
//  lint closes that gap: it makes adoption MANDATORY for exactly the tests that
//  can violate the invariant.
//
//  The invariant
//  =============
//  The only way a test can leave the suite non-quiescent (per the documented
//  root cause) is by assigning
//  `AccountsManager.deferInitialLoadCatalogsForTesting = false` and failing to
//  restore it — which then makes the next test class's `AppContainer.production()`
//  rebuild spawn a live registry crawl that starves the cooperative pool.
//
//  The rule
//  ========
//  Any PalaceTests Swift file that contains a real (non-comment, non-string)
//  `deferInitialLoadCatalogsForTesting = false` assignment MUST NOT declare a
//  test class that extends `XCTestCase` *directly*. Such a class must instead
//  extend `PalaceTestCase` (or `PalaceWiringTestCase`, which inherits it), so
//  the inherited `tearDown` quiescence assert deterministically fails the test
//  if it forgets to restore the flag. This holds under randomized test order
//  (`Palace.xcscheme` runs `testExecutionOrdering = "random"`), where a trailing
//  "final gate" test cannot.
//
//  What this gate DOES and does NOT catch (honest scope — see ADR)
//  ==============================================================
//  DOES: any test that sets the defer flag `false` without adopting the
//  quiescence base — structurally, at lint time, broadly across PalaceTests
//  (not a hard-coded file list).
//  DOES NOT: other quiescence leaks (un-cancelled detached Tasks, leaked
//  NotificationCenter observers, dirty disk cache) that do NOT route through
//  the defer flag. Those remain the domain of the existing `TearDownRequiredLintTests`
//  + `AccountsManagerIsolationLintTests` + `PalaceWiringTestCase` machinery.
//  The defer flag is the single documented starvation root cause; this gate
//  makes THAT class structurally impossible to reintroduce silently.
//
//  Why a Swift XCTest (not a shell grep): a hook flag (`--no-verify`) cannot
//  bypass it — if the suite runs, the rule runs. Mirrors
//  `AppContainerIsolationLintTests`.
//
//  swarm WS-0 / M0 (3.2.0 release gate).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import XCTest

final class RuntimeQuiescenceLintTests: XCTestCase {

    // MARK: - Resolution

    /// `PalaceTests/` resolved relative to this file's location.
    private static let palaceTestsRoot: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
    }()

    /// Self-referential exemption: this lint source contains the banned
    /// pattern in string fixtures for its own detector self-tests, so it must
    /// not flag itself (mirrors `AppContainerIsolationLintTests`' whitelist of
    /// its own file).
    private static let whitelist: Set<String> = [
        "MetaTests/RuntimeQuiescenceLintTests.swift",
    ]

    // MARK: - Detectors (pure, self-testable)

    /// True iff `line` is a real assignment of the defer flag to `false` —
    /// not a comment, not inside a string literal, not an `==` comparison.
    static func isDeferFlagFalseAssignment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") {
            return false
        }
        // Skip lines where the token appears inside a string literal — every
        // real assignment in the codebase has no `"` before the token.
        guard let tokenRange = line.range(of: "deferInitialLoadCatalogsForTesting") else {
            return false
        }
        if line[line.startIndex..<tokenRange.lowerBound].contains("\"") {
            return false
        }
        // Require `= false` (single `=`, not `==`) after the token.
        let after = line[tokenRange.upperBound...]
        guard let eq = after.range(of: "=") else { return false }
        // Reject `==` (comparison).
        let afterEq = after[eq.upperBound...]
        if after[eq.lowerBound...].hasPrefix("==") { return false }
        return afterEq.trimmingCharacters(in: .whitespaces).hasPrefix("false")
    }

    /// True iff `source` declares at least one class that extends `XCTestCase`
    /// directly (i.e. NOT the quiescence base). `PalaceTestCase` /
    /// `PalaceWiringTestCase` subclasses do not match because their inheritance
    /// clause names the base, not `XCTestCase`.
    static func declaresDirectXCTestCaseSubclass(_ source: String) -> Bool {
        // Matches `class Foo: XCTestCase` and `final class Foo: XCTestCase`,
        // with optional `@MainActor` etc. on prior tokens, and tolerates a
        // trailing protocol list (`: XCTestCase, Bar`).
        let pattern = #"class\s+\w+\s*:\s*XCTestCase\b"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// A file violates the gate iff it contains a real defer-flag-false
    /// assignment AND declares a direct `XCTestCase` subclass.
    static func fileViolates(_ source: String) -> Bool {
        let hasFalseAssignment = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { isDeferFlagFalseAssignment(String($0)) }
        guard hasFalseAssignment else { return false }
        return declaresDirectXCTestCaseSubclass(source)
    }

    // MARK: - File enumeration

    private func palaceTestSwiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.palaceTestsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(Self.palaceTestsRoot.path)")
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }

    private func relativePath(for url: URL) -> String {
        let abs = url.standardizedFileURL.path
        let root = Self.palaceTestsRoot.standardizedFileURL.path
        if abs.hasPrefix(root + "/") {
            return String(abs.dropFirst(root.count + 1))
        }
        return abs
    }

    // MARK: - Rule 1 — live scan

    /// Scans every PalaceTests Swift file and fails if any file that sets the
    /// defer flag `false` declares a direct `XCTestCase` subclass instead of
    /// adopting the quiescence base.
    func testNoDeferFlagFalseSetterExtendsXCTestCaseDirectly() throws {
        let files = try palaceTestSwiftFiles()
        XCTAssertFalse(files.isEmpty, "Expected at least one .swift file under PalaceTests/")

        var failures: [String] = []
        for url in files {
            let relPath = relativePath(for: url)
            if Self.whitelist.contains(relPath) { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if Self.fileViolates(source) {
                failures.append(
                    "\(relPath): sets `deferInitialLoadCatalogsForTesting = false` but declares a "
                    + "class extending `XCTestCase` directly. It MUST extend `PalaceTestCase` "
                    + "(or `PalaceWiringTestCase`) so the inherited tearDown quiescence assert "
                    + "catches a forgotten restore. See docs/architecture/runtime-quiescence-gate.md."
                )
            }
        }

        if !failures.isEmpty {
            XCTFail(
                "Runtime-quiescence lint (WS-0 / M0) — defer-flag-false setters must adopt the "
                + "quiescence base:\n\n" + failures.joined(separator: "\n")
            )
        }
    }

    // MARK: - Rule 2 — detector self-tests (prove BOTH paths, per green-board contract #4)

    /// BAD path: a direct `XCTestCase` subclass that sets the flag false MUST
    /// be flagged. Without this, a regex regression would silently disarm the
    /// lint.
    func testDetector_flagsDirectXCTestCaseSubclassThatSetsFalse() {
        let bad = """
        final class FooTests: XCTestCase {
            func testBar() {
                AccountsManager.deferInitialLoadCatalogsForTesting = false
            }
        }
        """
        XCTAssertTrue(Self.fileViolates(bad),
                      "A direct XCTestCase subclass setting the flag false MUST be flagged")
    }

    /// GOOD path: the SAME false-setting body, but the class adopts the
    /// quiescence base, MUST NOT be flagged. This is the clean-path assertion
    /// the green-board contract requires (a detector that only ever sees
    /// violations hides its own false-positives).
    func testDetector_passesQuiescenceBaseSubclassThatSetsFalse() {
        let goodPalaceTestCase = """
        final class FooTests: PalaceTestCase {
            func testBar() {
                AccountsManager.deferInitialLoadCatalogsForTesting = false
            }
        }
        """
        let goodWiring = """
        final class FooTests: PalaceWiringTestCase {
            func testBar() {
                AccountsManager.deferInitialLoadCatalogsForTesting = false
            }
        }
        """
        XCTAssertFalse(Self.fileViolates(goodPalaceTestCase),
                       "A PalaceTestCase subclass must NOT be flagged")
        XCTAssertFalse(Self.fileViolates(goodWiring),
                       "A PalaceWiringTestCase subclass must NOT be flagged")
    }

    /// CLEAN path: a file with no defer-flag-false assignment must never be
    /// flagged, even if it is a direct XCTestCase subclass.
    func testDetector_passesFileThatNeverSetsFalse() {
        let clean = """
        final class FooTests: XCTestCase {
            func testBar() {
                XCTAssertTrue(true)
            }
        }
        """
        XCTAssertFalse(Self.fileViolates(clean),
                       "A file that never sets the flag false must NOT be flagged")
    }

    /// The detector must ignore comment-only and string-literal mentions of
    /// the pattern (the auditor source + this lint reference it in prose).
    func testDetector_ignoresCommentsAndStringLiterals() {
        XCTAssertFalse(Self.isDeferFlagFalseAssignment(
            "// AccountsManager.deferInitialLoadCatalogsForTesting = false"),
            "A comment must not count as an assignment")
        XCTAssertFalse(Self.isDeferFlagFalseAssignment(
            #"detail += "set deferInitialLoadCatalogsForTesting = false here""#),
            "A string-literal mention must not count as an assignment")
        XCTAssertFalse(Self.isDeferFlagFalseAssignment(
            "XCTAssertFalse(AccountsManager.deferInitialLoadCatalogsForTesting == false)"),
            "An `==` comparison must not count as an assignment")
        XCTAssertTrue(Self.isDeferFlagFalseAssignment(
            "        AccountsManager.deferInitialLoadCatalogsForTesting = false"),
            "A real assignment MUST count")
    }
}
