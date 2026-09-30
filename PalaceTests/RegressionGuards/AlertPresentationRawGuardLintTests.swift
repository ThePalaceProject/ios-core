//
//  AlertPresentationRawGuardLintTests.swift
//  PalaceTests
//
//  Structural regression guard for the fe741015 CACommit crash family
//  (NSInternalInconsistencyException — "A view controller not containing an
//  alert controller was asked for its contained alert controller", the #1 crash
//  on 3.1.0). UIAlertCACommitGuardTests.swift holds the mechanism guard.
//
//  The crash is a deferred CA-commit throw, so it cannot be reproduced in a
//  unit test. This lint pins the invariant instead: the launch/book-open alert
//  sites must present through `TPPPresentationUtils.safelyPresent` or
//  `TPPAlertUtils.presentFromViewControllerOrNil` (which wait on the
//  presenter's `transitionCoordinator`), never a raw `present(alert)`. #1125
//  covered the main launch paths; this adds the LCP-PDF abort, Readium
//  module-error, and sync-position nil-coordinator sites.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import XCTest

@MainActor
final class AlertPresentationRawGuardLintTests: XCTestCase {

    // MARK: - Resolution

    /// Repo root resolved relative to this file
    /// (`<root>/PalaceTests/RegressionGuards/AlertPresentationRawGuardLintTests.swift`).
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RegressionGuards/
            .deletingLastPathComponent()  // PalaceTests/
            .deletingLastPathComponent()  // repo root
    }()

    /// The alert sites that raced the launch/book-open transition and were
    /// hardened for fe741015. A raw `UIAlertController` present in any of these
    /// is a regression.
    private static let guardedSites: [String] = [
        "Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift",
        "Palace/AppInfrastructure/ReaderService.swift",
        "Palace/Reader2/ReaderStackConfiguration/TPPR3Owner.swift",
    ]

    // MARK: - Detectors (pure, self-testable)

    /// True iff `line` presents an alert *raw* — a `.present(alert…` call that
    /// bypasses the coordinator-waiting guarded presenters. Comments do not
    /// count. The guarded calls do NOT match: `safelyPresent(` has no `.present(`
    /// substring and `presentFromViewControllerOrNil(` is `.presentFrom…`, not
    /// `.present(`.
    static func presentsAlertRaw(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") {
            return false
        }
        return line.range(of: #"\.present\(\s*alert"#, options: .regularExpression) != nil
    }

    /// True iff `source` routes alerts through a coordinator-waiting guarded
    /// presenter at least once — proves the fix is present, not merely that the
    /// raw pattern is absent (a file could drop alert presentation entirely and
    /// still pass rule 1).
    static func routesThroughGuardedPresenter(_ source: String) -> Bool {
        source.contains("safelyPresent(")
            || source.contains("presentFromViewControllerOrNil(")
    }

    // MARK: - Rule 1 — no raw alert present at the guarded sites

    func testGuardedSites_neverPresentAnAlertRaw() throws {
        var failures: [String] = []
        for relPath in Self.guardedSites {
            let url = Self.repoRoot.appendingPathComponent(relPath)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("Could not read guarded site: \(relPath) (at \(url.path))")
                continue
            }
            for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if Self.presentsAlertRaw(String(line)) {
                    failures.append("\(relPath):\(idx + 1): raw alert present() — must route through "
                        + "TPPPresentationUtils.safelyPresent or "
                        + "TPPAlertUtils.presentFromViewControllerOrNil (fe741015 CA-commit race)")
                }
            }
        }
        if !failures.isEmpty {
            XCTFail("fe741015 raw-alert-present guard tripped:\n\n" + failures.joined(separator: "\n"))
        }
    }

    // MARK: - Rule 2 — the fix is actually present at the guarded sites

    func testGuardedSites_routeThroughAGuardedPresenter() throws {
        for relPath in Self.guardedSites {
            let url = Self.repoRoot.appendingPathComponent(relPath)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("Could not read guarded site: \(relPath)")
                continue
            }
            XCTAssertTrue(Self.routesThroughGuardedPresenter(source),
                "\(relPath) must present its alert through a coordinator-waiting guarded "
                + "presenter — the fe741015 fix. If this file no longer presents any alert, "
                + "remove it from `guardedSites`.")
        }
    }

    // MARK: - Rule 3 — detector self-tests (BAD / GOOD / CLEAN per green-board contract #4)

    func testDetector_flagsRawAlertPresent() {
        XCTAssertTrue(Self.presentsAlertRaw("        top.present(alert, animated: true)"),
            "A raw `top.present(alert, …)` MUST be flagged")
        XCTAssertTrue(Self.presentsAlertRaw("            settledTop.present(alert, animated: true)"),
            "A raw `settledTop.present(alert, …)` MUST be flagged")
        XCTAssertTrue(Self.presentsAlertRaw("viewController.present( alert , animated: true)"),
            "Whitespace between `(` and `alert` MUST still be flagged")
    }

    func testDetector_passesGuardedPresenters() {
        XCTAssertFalse(Self.presentsAlertRaw("        TPPPresentationUtils.safelyPresent(alert, animated: true)"),
            "safelyPresent is a guarded presenter — must NOT be flagged")
        XCTAssertFalse(Self.presentsAlertRaw("        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert,"),
            "presentFromViewControllerOrNil is a guarded presenter — must NOT be flagged")
    }

    func testDetector_passesCommentsAndNonAlertPresents() {
        XCTAssertFalse(Self.presentsAlertRaw("// top.present(alert, animated: true) — old raced path"),
            "A `//` comment must NOT be flagged")
        XCTAssertFalse(Self.presentsAlertRaw("     * top.present(alert, animated: true) — old raced path"),
            "A `*` block-comment continuation line must NOT be flagged")
        XCTAssertFalse(Self.presentsAlertRaw("        /// top.present(alert) in a doc comment"),
            "A `///` doc-comment line must NOT be flagged")
        XCTAssertFalse(Self.presentsAlertRaw("        top.present(nav, animated: true)"),
            "Presenting a non-alert (nav) controller must NOT be flagged")
        XCTAssertFalse(Self.presentsAlertRaw("        base.present(payload.viewController, animated: animated)"),
            "Presenting a non-alert view controller must NOT be flagged")
    }

    func testDetector_routeDetector_bothPathsAndClean() {
        XCTAssertTrue(Self.routesThroughGuardedPresenter("x = TPPPresentationUtils.safelyPresent(alert)"),
            "safelyPresent presence MUST satisfy the route detector")
        XCTAssertTrue(Self.routesThroughGuardedPresenter("presentFromViewControllerOrNil(alertController: alert)"),
            "presentFromViewControllerOrNil presence MUST satisfy the route detector")
        XCTAssertFalse(Self.routesThroughGuardedPresenter("let alert = UIAlertController(title: t)"),
            "A file that never routes through a guarded presenter must NOT satisfy the route detector")
    }
}
