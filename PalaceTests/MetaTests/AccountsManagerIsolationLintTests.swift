//
//  AccountsManagerIsolationLintTests.swift
//  PalaceTests
//
//  Meta-test enforcing the AccountsManager-isolation hygiene rule
//  introduced by swarm_47883816 Module B (test pollution sweep):
//
//    Bare `AccountsManager()` constructions are forbidden in
//    PalaceTests/** outside a tightly-scoped whitelist. All other test
//    sites MUST go through `PalaceWiringTestCase.makeFreshAccountsManager()`
//    (or the live-load sibling helper) so the base class's
//    cancel-background-work + Combine-bag-drain + disk-cache-purge
//    guarantees fire automatically on tearDown.
//
//  Why this matters: a bare `AccountsManager()` in a test method spawns
//  a background `loadCatalogs` Task that outlives the test, retains
//  Combine sinks, and writes the bundled-catalog snapshot into the
//  shared Application Support directory. The next test in the bundle
//  inherits that state. swarm_4b64e4e0 Wave 1c built the wiring base
//  class to close this exact leak; this lint pins the contract so the
//  pattern can't drift back in.
//
//  Whitelist (any new entry requires a paired wall-failure entry):
//   - PalaceTests/Support/PalaceWiringTestCase.swift           — the seam itself
//   - PalaceTests/Support/PalaceWiringTestCaseTests.swift      — tests the seam
//   - PalaceTests/AppInfrastructure/AppContainerResetTests.swift — comment-only
//                                                                 historical refs
//   - PalaceTests/Mocks/**                                     — mock-side
//                                                                 implementations
//   - PalaceTests/Support/TestAppContainerFactory*.swift       — Module A's
//                                                                 factory seam
//                                                                 (defers init
//                                                                 the same way)
//
//  Implementation: plain text scan, no SwiftSyntax. Line-based so a
//  method declaration `func testFoo_AccountsManager_path() {` that
//  contains the substring is correctly skipped via the `func ` test.
//
//  swarm_47883816 Module B.
//

import Foundation
import XCTest
import PalaceBookRegistry

@MainActor
final class AccountsManagerIsolationLintTests: XCTestCase {

    // MARK: - Resolution

    /// PalaceTests/ directory resolved relative to this file's location so
    /// the test works in every checkout (no env vars, no CI-specific paths).
    private static let palaceTestsRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MetaTests/
            .deletingLastPathComponent()  // PalaceTests/
    }()

    /// Whitelist of file paths (relative to `palaceTestsRoot`) allowed to
    /// contain bare `AccountsManager(` constructions. Anything else
    /// triggers a lint failure.
    ///
    /// We match by suffix-of-relative-path so adding a new directory
    /// doesn't need a rewrite, and so the test is robust to absolute-vs-
    /// relative URL representations.
    private static let whitelistSuffixes: [String] = [
        "Support/PalaceWiringTestCase.swift",
        "Support/PalaceWiringTestCaseTests.swift",
        "AppInfrastructure/AppContainerResetTests.swift",
        // Module A's factory seam — also defers loadCatalogs the same way
        // PalaceWiringTestCase does. Owned by sibling swarm contract.
        "Support/TestAppContainerFactory.swift",
        "Support/TestAppContainerFactoryTests.swift",
        // Module E's TearDownRequired lint contains "AccountsManager("
        // as a polluter-substring fixture; it cannot avoid the literal
        // without breaking its own scanner. Self-referential exemption.
        "MetaTests/TearDownRequiredLintTests.swift",
        // The SUT's own unit test — it must construct `AccountsManager`
        // directly (incl. the DI `AccountsManager(defaults:)` form) to
        // exercise the class under test. Every construction site pins
        // `deferInitialLoadCatalogsForTesting = true` and a
        // `defer { manager.cancelBackgroundWork() }`, so it does not leak
        // background `loadCatalogs` work — the exact hazard this lint
        // guards against. The file carries its own setUp/tearDown +
        // setUpWithError lifecycle, so migrating it to
        // PalaceWiringTestCase is higher-risk than the manual seam.
        "Accounts/AccountsManagerTests.swift",
    ]

    /// True if `url` lives under PalaceTests/Mocks/ (recursive).
    private func isInMocksDirectory(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/PalaceTests/Mocks/")
    }

    /// True if `url` is one of the whitelisted file suffixes.
    private func isWhitelisted(_ url: URL) -> Bool {
        let path = url.path
        return Self.whitelistSuffixes.contains { path.hasSuffix($0) }
    }

    /// All `*.swift` files under `PalaceTests/` (recursive).
    private func allTestFiles() throws -> [URL] {
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
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            files.append(url)
        }
        return files
    }

    /// Read a file as UTF-8, returning nil on failure.
    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Detector

    /// Returns the line numbers (1-indexed) in `source` that contain a
    /// CALL to `AccountsManager(...)` — distinguishing calls from
    /// declarations, comments, and string-literal mentions.
    ///
    /// A "bare AccountsManager() call" for this lint's purpose is a
    /// non-comment line containing the substring `AccountsManager(`
    /// where:
    ///   - the line is NOT a `//` comment (whole-line ignore)
    ///   - the line does NOT contain `func ` before `AccountsManager(`
    ///     (function declaration whose name embeds the type)
    ///   - the line does NOT contain `class ` before `AccountsManager(`
    ///     (impossible in Swift but cheap to check)
    ///   - the line does NOT contain `makeFreshAccountsManager(`
    ///     (the seam-correct form)
    ///   - the line does NOT contain `"` before `AccountsManager(`
    ///     pattern indicating string-literal mention (best-effort —
    ///     `"foo AccountsManager(`)
    static func scanForBareConstructions(in source: String) -> [Int] {
        var hits: [Int] = []
        let lines = source.components(separatedBy: "\n")
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            // Whole-line `//` comment — strip.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            // Must mention the constructor at all.
            guard let amRange = line.range(of: "AccountsManager(") else { continue }
            // Strip any `//` inline-comment tail BEFORE the AccountsManager
            // hit so e.g. `let x = foo() // AccountsManager()` is ignored.
            if let commentRange = line.range(of: "//"), commentRange.lowerBound < amRange.lowerBound {
                continue
            }
            // Filter declarations: `func ...AccountsManager(` is a method
            // signature, not a call. Same for `class ` (defensive).
            let prefix = String(line[..<amRange.lowerBound])
            if prefix.contains("func ") { continue }
            if prefix.contains("class ") { continue }
            // Filter the seam-correct form. `makeFreshAccountsManager(` is
            // allowed; if the line contains it, the `AccountsManager(`
            // match is part of that token.
            if prefix.hasSuffix("makeFresh") { continue }
            // String-literal heuristic: if the prefix ends with an odd
            // number of unescaped `"`, we're inside a string.
            let quoteCount = prefix.reduce(into: 0) { count, ch in
                if ch == "\"" { count += 1 }
            }
            if quoteCount % 2 == 1 { continue }
            hits.append(idx + 1)
        }
        return hits
    }

    // MARK: - 1. Real-codebase scan — no bare AccountsManager() outside whitelist

    /// The codebase-wide lint check: scan every PalaceTests/*.swift file,
    /// skip the whitelist, fail if any other file contains a bare
    /// `AccountsManager(` call.
    func testNoBareAccountsManagerOutsideWhitelist() throws {
        let files = try allTestFiles()
        XCTAssertFalse(files.isEmpty, "No PalaceTests files discovered at \(Self.palaceTestsRoot.path)")

        var violations: [(file: String, lines: [Int])] = []
        for url in files {
            if isWhitelisted(url) { continue }
            if isInMocksDirectory(url) { continue }
            // Skip THIS file — it mentions `AccountsManager(` in literals
            // (the synthetic-violator test below).
            if url.path.hasSuffix("MetaTests/AccountsManagerIsolationLintTests.swift") { continue }
            guard let src = contents(of: url) else {
                XCTFail("Could not read \(url.lastPathComponent)")
                continue
            }
            let hits = Self.scanForBareConstructions(in: src)
            if !hits.isEmpty {
                // Render path relative to PalaceTests/ root for readability.
                let rel = String(url.path.dropFirst(Self.palaceTestsRoot.path.count + 1))
                violations.append((file: rel, lines: hits))
            }
        }

        if !violations.isEmpty {
            let rendered = violations
                .map { "\($0.file):\($0.lines.map(String.init).joined(separator: ","))" }
                .sorted()
                .joined(separator: "\n  ")
            XCTFail("""
            Bare `AccountsManager()` constructions found in PalaceTests/ outside the whitelist. \
            Test files MUST use `PalaceWiringTestCase.makeFreshAccountsManager()` (or the \
            live-load sibling) so the base class's tearDown cancellation hook fires. \
            See PalaceTests/Support/PalaceWiringTestCase.swift for the seam. \
            Violations:
              \(rendered)
            """)
        }
    }

    // MARK: - 2. Synthetic-violator check — the detector is not a no-op

    /// Synthetic-violator harness: feed the detector a string that
    /// MUST trip it, and assert it does. Without this, a bug that
    /// causes `scanForBareConstructions` to return `[]` unconditionally
    /// would silently make the lint above pass.
    ///
    /// Covers four shapes:
    ///   - assignment: `accountsManager = AccountsManager()`
    ///   - inline construction: `Foo(accountsManager: AccountsManager(), ...)`
    ///   - let-binding: `let m = AccountsManager()`
    ///   - mid-expression: `someFunc(arg: AccountsManager())`
    ///
    /// AND four shapes that must NOT trip:
    ///   - method declaration: `func testFoo_AccountsManager() { }`
    ///   - comment: `// AccountsManager() must be replaced`
    ///   - inline-trailing comment: `let x = foo() // AccountsManager()`
    ///   - seam-correct: `let m = makeFreshAccountsManager()`
    ///   - string literal: `let msg = "Use AccountsManager() correctly"`
    func testLintCatchesSyntheticViolator() {
        let positives = """
        accountsManager = AccountsManager()
        let registry = TPPBookRegistry(accountsManager: AccountsManager(), imageLoader: nil)
        let m = AccountsManager()
        someFunc(arg: AccountsManager())
        """
        let positiveHits = Self.scanForBareConstructions(in: positives)
        XCTAssertEqual(
            positiveHits.count, 4,
            "Detector must flag all 4 bare-constructor shapes — got \(positiveHits.count). Hits: \(positiveHits)"
        )

        let negatives = """
        func testWithAccount_inheritsParentAccountsManager() {
            // AccountsManager() must be replaced with the seam.
            let m = makeFreshAccountsManager()
            let msg = "Use AccountsManager() correctly"
            let x = foo() // AccountsManager() inline comment
        }
        """
        let negativeHits = Self.scanForBareConstructions(in: negatives)
        XCTAssertTrue(
            negativeHits.isEmpty,
            "Detector must NOT flag declarations, comments, seam calls, or string literals — got hits at \(negativeHits)"
        )
    }

    // MARK: - 3. GAP 2 — construction sites must live in a wiring-base class

    /// Files (with reason) exempt from the "class extends `PalaceWiringTestCase`"
    /// requirement below. These are the SEAMS that legitimately construct
    /// `AccountsManager` directly and already pin
    /// `deferInitialLoadCatalogsForTesting = true` + a `cancelBackgroundWork()`
    /// teardown, OR carry the constructor substring only inside fixture strings
    /// for their own scanners. Any NEW entry must be paired with a wall-failure
    /// note (same rule as the bare-construction whitelist above).
    private static let wiringBaseAllowlistSuffixes: [String] = [
        // The seam itself — `makeFreshAccountsManager()` builds the manager here.
        "Support/PalaceWiringTestCase.swift",
        // Module A's factory seam — defers loadCatalogs the same way.
        "Support/TestAppContainerFactory.swift",
        "Support/TestAppContainerFactoryTests.swift",
        // Fixture-carrier: the constructor substring appears only inside the
        // detector's own synthetic-source `"""..."""` fixtures.
        "MetaTests/TearDownRequiredLintTests.swift",
        // SUT's own unit test. It constructs `AccountsManager(defaults:)` to
        // exercise the class under test; every site pins
        // `deferInitialLoadCatalogsForTesting = true` + `defer {
        // manager.cancelBackgroundWork() }`, so it does not leak background
        // work. It carries a bespoke setUp/tearDown lifecycle, so migrating it
        // to `PalaceWiringTestCase` is higher-risk than the manual seam.
        // TODO(PP-pollfix): evaluate migrating `AccountsManagerTests` +
        // `AccountAuthDocCarryoverTests` onto `PalaceWiringTestCase` once the
        // manual-lifecycle assertions are reconciled with the base's drain.
        "Accounts/AccountsManagerTests.swift",
    ]

    private func isWiringBaseAllowlisted(_ url: URL) -> Bool {
        let path = url.path
        return Self.wiringBaseAllowlistSuffixes.contains { path.hasSuffix($0) }
    }

    /// True iff `source` declares (or a class in it extends) the wiring base.
    /// Substring match is sufficient: a test file that constructs
    /// `AccountsManager` and legitimately inherits the tearDown guarantees will
    /// contain `: PalaceWiringTestCase` in its class declaration.
    static func declaresWiringBase(in source: String) -> Bool {
        source.contains(": PalaceWiringTestCase")
    }

    /// GAP 2 regression lint: any PalaceTests file that CONSTRUCTS
    /// `AccountsManager(` must either (a) be a class extending
    /// `PalaceWiringTestCase` — so `cancelBackgroundWork()` + Combine-bag drain
    /// + disk-cache purge fire on tearDown and the deferred auth-doc main-hop is
    /// flushed at the boundary — or (b) be on the explicit
    /// `wiringBaseAllowlistSuffixes` seam list above. This is the class-base
    /// complement to `testNoBareAccountsManagerOutsideWhitelist` (which forbids
    /// *bare* constructions): it pins the positive requirement that the
    /// construction lives where the isolation guarantees exist.
    func testAccountsManagerConstructionSites_extendWiringBase_orAllowlisted() throws {
        let files = try allTestFiles()
        XCTAssertFalse(files.isEmpty, "No PalaceTests files discovered at \(Self.palaceTestsRoot.path)")

        var violations: [(file: String, lines: [Int])] = []
        for url in files {
            if isInMocksDirectory(url) { continue }
            // Skip THIS file — its `AccountsManager(` mentions are detector
            // literals / synthetic-violator fixtures, not real constructions.
            if url.path.hasSuffix("MetaTests/AccountsManagerIsolationLintTests.swift") { continue }
            guard let src = contents(of: url) else {
                XCTFail("Could not read \(url.lastPathComponent)")
                continue
            }
            let hits = Self.scanForBareConstructions(in: src)
            guard !hits.isEmpty else { continue }
            if isWiringBaseAllowlisted(url) { continue }
            if Self.declaresWiringBase(in: src) { continue }
            let rel = String(url.path.dropFirst(Self.palaceTestsRoot.path.count + 1))
            violations.append((file: rel, lines: hits))
        }

        if !violations.isEmpty {
            let rendered = violations
                .map { "\($0.file):\($0.lines.map(String.init).joined(separator: ","))" }
                .sorted()
                .joined(separator: "\n  ")
            XCTFail("""
            `AccountsManager(` constructed in PalaceTests/ files whose class does NOT extend \
            `PalaceWiringTestCase` and which are NOT on the seam allowlist. Move the test onto \
            `PalaceWiringTestCase` (so the tearDown cancel + boundary main-hop flush fire), or \
            add the file to `wiringBaseAllowlistSuffixes` with a reason + wall-failure note. \
            Violations:
              \(rendered)
            """)
        }
    }

    /// Teeth for the class-base detector: a synthetic construction site with NO
    /// wiring base must be flagged; the same content WITH the base must not.
    func testWiringBaseLint_syntheticViolator() {
        let withoutBase = """
        @MainActor
        final class RogueAccountsTests: XCTestCase {
            func testThing() {
                let m = AccountsManager()
                _ = m
            }
        }
        """
        XCTAssertFalse(
            Self.scanForBareConstructions(in: withoutBase).isEmpty,
            "Precondition: the synthetic rogue must contain a real construction"
        )
        XCTAssertFalse(
            Self.declaresWiringBase(in: withoutBase),
            "A plain-XCTestCase construction site must be detected as lacking the wiring base"
        )

        let withBase = """
        @MainActor
        final class ProperAccountsTests: PalaceWiringTestCase {
            func testThing() {
                let m = AccountsManager()
                _ = m
            }
        }
        """
        XCTAssertTrue(
            Self.declaresWiringBase(in: withBase),
            "A `: PalaceWiringTestCase` construction site must be recognised as wiring-based"
        )
    }
}
