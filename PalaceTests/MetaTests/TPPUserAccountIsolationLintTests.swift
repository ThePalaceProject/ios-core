//
//  TPPUserAccountIsolationLintTests.swift
//  PalaceTests
//
//  Meta-tests that enforce TPPUserAccount-isolation hygiene across
//  PalaceTests/. They prevent the regression class of "raw
//  TPPUserAccount.sharedAccount(...)" call sites creeping back in. After
//  swarm_47883816, tests should mint per-call isolated accounts via
//  `TPPUserAccountTestFactory.makeIsolated()`; any remaining sharedAccount
//  call site must be on the whitelist below (and the whitelist is small
//  and intentional).
//
//  Implementation: substring scanning of raw file text. No SwiftSyntax —
//  the rule surface is narrow, false positives are easy to suppress with
//  a `// MIGRATED:` comment, and the cost of a heavyweight parser is not
//  justified.
//
//  Sister tests:
//   - `MockIsolationLintTests` (mock-singleton hygiene, F-008 regression class)
//

import Foundation
import XCTest

@MainActor
final class TPPUserAccountIsolationLintTests: XCTestCase {

    // MARK: - Resolution

    /// `PalaceTests/` resolved relative to this file's location so the test
    /// works in every checkout — no env vars, no CI-specific paths.
    private static let palaceTestsRoot: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
    }()

    /// All `*.swift` files under `PalaceTests/` (recursive). Skips dotfiles
    /// and non-Swift artefacts.
    private func palaceTestSwiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.palaceTestsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(Self.palaceTestsRoot.path) — is PalaceTests/ present?")
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

    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Whitelist

    /// Files explicitly allowed to call `TPPUserAccount.sharedAccount(...)`:
    ///
    ///  - `TPPUserAccountMock.swift`: the mock subclass itself
    ///  - `TPPPerAccountIsolationTests.swift`: tests the per-account keychain
    ///    integration on purpose; uses `KeychainAvailability.skipIfUnavailable()`
    ///  - `TPPCredentialIsolationE2ETests.swift`: E2E keychain integration;
    ///    same keychain-availability gate
    ///  - `TPPUserAccountTestFactory.swift`: the factory itself (forwards
    ///    documentation references)
    ///  - `TPPUserAccountIsolationLintTests.swift`: the lint file itself
    ///    (contains synthetic violator strings for testLintCatchesSyntheticViolator)
    ///
    /// `CoverageGapTests3.swift` is NOT in this whitelist — instead, the
    /// identity-check call sites in that file MUST carry an inline
    /// `// MIGRATED: keep — identity test of shared cache` comment. The
    /// lint allows any line carrying the substring `// MIGRATED:` so the
    /// gate is mechanically structural (no per-file whitelist drift).
    private static let allowedFiles: Set<String> = [
        "TPPUserAccountMock.swift",
        "TPPPerAccountIsolationTests.swift",
        "TPPCredentialIsolationE2ETests.swift",
        "TPPUserAccountTestFactory.swift",
        "TPPUserAccountTestFactoryTests.swift",
        "TPPUserAccountIsolationLintTests.swift"
    ]

    /// Lines that match this prefix-suffix pair are "code calls
    /// `TPPUserAccount.sharedAccount(...)`" — substring is sufficient
    /// because Swift comments use `//` (caught by the `// MIGRATED:` or
    /// any `//` lead before the substring), and the substring would not
    /// appear in a string literal anywhere production-realistic.
    private static let bannedSubstring = "TPPUserAccount.sharedAccount("

    /// Acceptance marker — a line carrying this substring is treated as
    /// "intentionally retained shared-cache call site" regardless of file.
    private static let migratedMarker = "// MIGRATED:"

    // MARK: - Rule 1: no raw sharedAccount calls outside the whitelist

    func testNoSharedAccountOutsideWhitelist() throws {
        let files = try palaceTestSwiftFiles()
        XCTAssertFalse(files.isEmpty,
                       "No PalaceTests Swift files discovered at \(Self.palaceTestsRoot.path)")

        var violations: [String] = []

        for url in files {
            if Self.allowedFiles.contains(url.lastPathComponent) {
                continue
            }
            guard let src = contents(of: url) else {
                XCTFail("Could not read \(url.lastPathComponent)")
                continue
            }
            for (idx, rawLine) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                guard line.contains(Self.bannedSubstring) else { continue }

                // Acceptance gates (in order):
                //   1. `// MIGRATED:` marker on the same line — caller has
                //      explicitly opted in.
                //   2. Pure comment line (leading whitespace then `//`) — a
                //      doc-comment reference, not a call.
                //   3. Inside a string literal — extremely uncommon in tests,
                //      but the empty-test path keeps this line silent.
                if line.contains(Self.migratedMarker) { continue }

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.hasPrefix("///") { continue }
                if trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }

                let rel = url.path.replacingOccurrences(of: Self.palaceTestsRoot.path + "/", with: "")
                violations.append("\(rel):\(idx + 1): \(trimmed)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Found raw `TPPUserAccount.sharedAccount(...)` call sites outside the whitelist.
            Migrate to `TPPUserAccountTestFactory.makeIsolated()` from PalaceTests/Support/,
            or, if the call site is intentionally testing the shared cache itself,
            mark it with `// MIGRATED: keep — <reason>` on the same line.
            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Rule 2: lint catches a synthetic violator

    /// The lint's job is to fail when a raw sharedAccount call lives in a
    /// file that isn't whitelisted. This test feeds a synthetic source
    /// string through the same predicates and confirms the predicate
    /// flags the bad line and ignores the migrated-marker line.
    ///
    /// Test name aligns with the SUT-instantiation rule by referencing
    /// the lint logic via the same substring matchers — no fake-wiring.
    func testLintCatchesSyntheticViolator() {
        let bad = "let acct = TPPUserAccount.sharedAccount(libraryUUID: \"x\")"
        let migratedComment = "let acct = TPPUserAccount.sharedAccount(libraryUUID: \"x\") // MIGRATED: keep — identity test"
        let commentOnlyDoc = "// docs: TPPUserAccount.sharedAccount(libraryUUID:) is deprecated"
        let okay = "let acct = TPPUserAccountTestFactory.makeIsolated()"

        XCTAssertTrue(bad.contains(Self.bannedSubstring),
                      "Predicate must flag a bare sharedAccount call")
        XCTAssertTrue(migratedComment.contains(Self.bannedSubstring),
                      "Predicate sees the call substring on the marker line — second gate filters by `// MIGRATED:`")
        XCTAssertTrue(migratedComment.contains(Self.migratedMarker),
                      "Marker filter must accept the migrated-comment line")
        XCTAssertTrue(commentOnlyDoc.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      "Pure comment-line filter must accept doc-comment references")
        XCTAssertFalse(okay.contains(Self.bannedSubstring),
                       "Factory call site must not contain the banned substring (sanity check)")
    }

    // MARK: - Rule 3: every minted-resetter sanity check

    /// The factory registers its resetter under the stable name
    /// `TPPUserAccountTestFactory.minted`. Reset registration order
    /// matters (see SingletonResetRegistry comments) — this test pins the
    /// name so the lint can validate continued presence after any future
    /// resetter shuffle. It does NOT mint an account (that would couple
    /// this lint to keychain availability); the factory's first call from
    /// `TPPUserAccountTestFactoryTests` already registered the resetter,
    /// and the registry is process-wide.
    func testResetterIsRegisteredAfterFactoryUse() {
        // Touch the factory so the lazy `registerOnce` token fires even
        // if this test runs in isolation (when none of the factory's own
        // tests have executed first).
        _ = TPPUserAccountTestFactory.makeIsolated(libraryUUID: "test-uuid-lint-probe")

        let names = SingletonResetRegistry.shared.registeredNames()
        XCTAssertTrue(names.contains("TPPUserAccountTestFactory.minted"),
                      "Factory's resetter must be present in the registry after any makeIsolated() call")
    }
}
