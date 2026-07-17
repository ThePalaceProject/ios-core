//
//  TearDownRequiredLintTests.swift
//  PalaceTests
//
//  Lint enforcement for swarm_47883816 work package E:
//  test classes that touch process-wide polluter state MUST declare a
//  `tearDown` override (or inherit from a `*TestCase` base class whose
//  tearDown handles the cleanup).
//
//  Failure mode this lint closes
//  =============================
//  A test class that calls `.shared` singletons, constructs
//  `AccountsManager()`, reads `AppContainer.production()`, registers
//  observers on `NotificationCenter.default`, or writes to
//  `UserDefaults.standard` MUST have a tearDown that drops the
//  acquisition. Without a tearDown, the next test in the bundle
//  inherits the polluted state — the F-008 regression class
//  (2026-05-14) and the swarm_4b64e4e0 Wave 1c motivation.
//
//  How the rule works
//  ==================
//  Files relevant to the lint:
//
//    - Must be a Swift file under `PalaceTests/`
//    - Must declare a class extending `XCTestCase` (direct extension).
//      Classes extending a `*TestCase` base (e.g. `PalaceWiringTestCase`)
//      are EXEMPT — the base handles tearDown by inheritance.
//    - Must contain at least one polluter substring:
//        `.shared`                              (singleton access)
//        `AccountsManager(`                     (constructor)
//        `AppContainer.production()`            (production graph read)
//        `NotificationCenter.default.addObserver`
//        `UserDefaults.standard.set`
//
//  Compliance requires ONE of:
//
//    - `override func tearDown()`
//    - `override func tearDownWithError()`
//    - `override func tearDown() async throws`
//
//  Exception: the BASELINE file
//  (`.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt`) lists
//  37 current XCTestCase-derived files that touch polluters without
//  tearDown. The lint exempts these explicitly so the suite stays
//  green at landing time. The list can only SHRINK:
//   - Files that gain a tearDown drop off the list (the lint stays
//     green for them whether they're listed or not).
//   - Files added to PalaceTests/ that fit the trigger but aren't on
//     the list trigger a lint failure (the structural protection).
//
//  Why a Swift XCTest rather than a shell grep gate
//  ================================================
//  Hook-based shell scripts have two failure modes the harness has
//  seen before:
//   - They no-op gracefully on missing dependencies (forge-os scripts).
//   - They're easy to bypass via `--no-verify`.
//  An XCTest that runs in the same xctest process as the suite itself
//  cannot be bypassed by a hook flag; if the test runs, the rule runs.
//
//  swarm_47883816 work package E.
//

import Foundation
import XCTest

@MainActor
final class TearDownRequiredLintTests: XCTestCase {

  // MARK: - Resolution

  /// `PalaceTests/` resolved relative to this file's location.
  private static let palaceTestsRoot: URL = {
    URL(fileURLWithPath: #file)
      .deletingLastPathComponent()  // MetaTests/
      .deletingLastPathComponent()  // PalaceTests/
  }()

  /// Repo root — one level above `PalaceTests/`. Used to resolve the
  /// baseline file at `.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt`.
  private static let repoRoot: URL = {
    palaceTestsRoot.deletingLastPathComponent()
  }()

  /// Loaded baseline — paths relative to repo root that are exempt
  /// from the lint. The file is read once at static init; if the file
  /// is missing, the baseline is empty (so a misconfigured CI path
  /// fails LOUDER, not silently).
  private static let baselinedFiles: Set<String> = {
    let path = repoRoot
      .appendingPathComponent(".forgeos/swarms/swarm_47883816/E-teardown-baseline.txt")
    guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
      return []
    }
    return Set(
      contents.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    )
  }()

  /// Polluter substrings that trigger the tearDown requirement.
  ///
  /// **`.shared` is a broad match** — it matches `UserDefaults.standard`?
  /// No: the substring is `.shared`, which catches `TPPBookRegistry.shared`,
  /// `AccountsManager.shared`, `TPPUserAccount.shared`, etc. Substring
  /// matching is deliberate; finer scoping would invite escape hatches.
  private static let polluterSubstrings: [String] = [
    ".shared",
    "AccountsManager(",
    "AppContainer.production()",
    "NotificationCenter.default.addObserver",
    "UserDefaults.standard.set",
  ]

  // MARK: - Detector helpers

  /// All `.swift` files under `PalaceTests/`, skipping the MetaTests/
  /// directory itself (the lint sources contain polluter substrings in
  /// string literals — they would self-trigger).
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
      if url.path.contains("/PalaceTests/MetaTests/") { continue }
      files.append(url)
    }
    return files
  }

  private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Returns the file's path relative to the repo root, so it can be
  /// matched against the baseline list (which lists `PalaceTests/...`).
  private func repoRelativePath(for url: URL) -> String {
    let abs = url.standardizedFileURL.path
    let root = Self.repoRoot.standardizedFileURL.path
    if abs.hasPrefix(root + "/") {
      return String(abs.dropFirst(root.count + 1))
    }
    return abs
  }

  /// True if `source` declares a class that directly extends
  /// `XCTestCase`. Multi-line class headers are not handled (rare in
  /// this codebase — see lint self-tests below for the patterns
  /// covered).
  static func declaresXCTestCaseSubclass(_ source: String) -> Bool {
    // class Foo: XCTestCase
    // final class Foo: XCTestCase
    // public class Foo: XCTestCase
    // class Foo : XCTestCase
    // class Foo: XCTestCase, SomeProtocol
    // Comment lines are stripped first to avoid doc-comment false
    // positives.
    let code = source
      .components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    let pattern = #"\bclass\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*XCTestCase\b"#
    return code.range(of: pattern, options: .regularExpression) != nil
  }

  /// True if `source` declares a class extending a `*TestCase` base
  /// other than `XCTestCase` itself. Such classes are EXEMPT — the
  /// base class drives tearDown via inheritance.
  static func declaresTestCaseBaseSubclass(_ source: String) -> Bool {
    let code = source
      .components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    // Match `<identifier>TestCase` where the identifier is not just "XC".
    // We match `: <something>TestCase` then check it's not exactly
    // "XCTestCase". Cheaper: a positive regex for any prefix BEFORE
    // "TestCase" that's not "XC".
    //
    // Practical implementation: collect every `: <Word>` in class
    // headers and look for any whose word ends in `TestCase` but isn't
    // `XCTestCase`.
    let headerPattern = #"\bclass\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*([A-Za-z_][A-Za-z0-9_]*)"#
    guard let re = try? NSRegularExpression(pattern: headerPattern) else { return false }
    let range = NSRange(code.startIndex..., in: code)
    let matches = re.matches(in: code, range: range)
    for match in matches {
      guard let g1 = Range(match.range(at: 1), in: code) else { continue }
      let baseName = String(code[g1])
      if baseName.hasSuffix("TestCase") && baseName != "XCTestCase" {
        return true
      }
    }
    return false
  }

  /// True if `source` contains any polluter substring.
  static func containsPolluter(_ source: String) -> Bool {
    for needle in polluterSubstrings {
      if source.contains(needle) { return true }
    }
    return false
  }

  /// True if `source` declares an override of one of the recognised
  /// tearDown forms.
  static func hasTearDownOverride(_ source: String) -> Bool {
    // override func tearDown()
    // override func tearDownWithError()
    // override func tearDown() async throws
    let pattern = #"override\s+func\s+tearDown(WithError)?\s*\("#
    return source.range(of: pattern, options: .regularExpression) != nil
  }

  // MARK: - Rule 1 — polluter-touching test classes need tearDown

  /// Scans every Swift file under `PalaceTests/` and fails with a
  /// per-file breakdown if any file triggers all three of:
  ///
  ///  (a) declares a class extending `XCTestCase` directly (not a
  ///      `*TestCase` base)
  ///  (b) contains at least one polluter substring
  ///  (c) lacks an `override func tearDown` form
  ///  (d) is NOT in the baseline exempt list
  func testTearDownRequired_runsAgainstPalaceTestsTree() throws {
    let files = try palaceTestSwiftFiles()
    XCTAssertFalse(files.isEmpty,
                   "Expected at least one .swift file under PalaceTests/")

    XCTAssertFalse(Self.baselinedFiles.isEmpty,
                   "Expected E-teardown-baseline.txt to load with at least one entry — if this fails, the resolver path is wrong or the file is missing")

    var violations: [String] = []

    for url in files {
      let repoRel = repoRelativePath(for: url)
      // Baselined files are exempt regardless of content.
      if Self.baselinedFiles.contains(repoRel) {
        continue
      }
      guard let src = contents(of: url) else {
        violations.append("\(repoRel): could not read file as UTF-8")
        continue
      }
      // Trigger 1: must declare an XCTestCase subclass.
      guard Self.declaresXCTestCaseSubclass(src) else { continue }
      // Trigger 2: must touch a polluter substring.
      guard Self.containsPolluter(src) else { continue }
      // Trigger 3: must NOT already declare a tearDown override.
      if Self.hasTearDownOverride(src) { continue }
      // All triggers fired — this is a new violator that escaped the
      // baseline. Either add a `tearDown` or rebase the file to a
      // `*TestCase` base. (Adding to the baseline is REJECTED — the
      // list is shrink-only.)
      violations.append(repoRel)
    }

    if !violations.isEmpty {
      XCTFail(
        """
        TearDown lint violation — swarm_47883816 work package E:

        \(violations.sorted().joined(separator: "\n"))

        These files extend XCTestCase directly and touch process-wide
        polluter state (.shared / AccountsManager() / AppContainer.production() /
        NotificationCenter.default.addObserver / UserDefaults.standard.set)
        without an `override func tearDown` to drop the acquisition.

        Options to remediate (in order of preference):
          1. Add `override func tearDownWithError() throws { ... try super.tearDownWithError() }`
             that drops the singleton / observer / UserDefaults key acquired in setUp.
          2. Migrate the class to `PalaceWiringTestCase` (PalaceTests/Support/) —
             the base drains Combine subscriptions, cancels background work,
             and clears the test UserDefaults suite on tearDown automatically.
          3. If the file genuinely cannot have a tearDown (rare — e.g. it's a
             pure-protocol-conformance test that touches no real state),
             open a discussion before mutating `E-teardown-baseline.txt`.
             The baseline is SHRINK-ONLY.
        """
      )
    }
  }

  // MARK: - Rule 2 — lint self-tests (proves the detectors actually fire)

  /// Synthetic violator: declares `: XCTestCase`, mentions a polluter,
  /// has no tearDown. Detector MUST trip on it.
  func testLintCatchesSyntheticViolator() {
    let synthetic = """
    import XCTest

    @MainActor
    final class SyntheticPolluterTests: XCTestCase {
        func testFoo() {
            let manager = AccountsManager()
            _ = manager
        }
    }
    """
    XCTAssertTrue(
      Self.declaresXCTestCaseSubclass(synthetic),
      "Detector must recognise a direct `: XCTestCase` extension"
    )
    XCTAssertTrue(
      Self.containsPolluter(synthetic),
      "Detector must recognise the `AccountsManager(` polluter substring"
    )
    XCTAssertFalse(
      Self.hasTearDownOverride(synthetic),
      "Detector must NOT see a tearDown in the violator (there is none)"
    )
  }

  /// Synthetic compliant case: declares `: SomethingTestCase` (NOT
  /// XCTestCase directly). Detector MUST NOT flag it — inheritance
  /// handles teardown.
  func testLintAcceptsInheritedTearDown() {
    let inherited = """
    import XCTest

    @MainActor
    final class SyntheticInheritedTests: PalaceWiringTestCase {
        func testFoo() {
            let manager = AccountsManager()
            _ = manager
        }
    }
    """
    XCTAssertFalse(
      Self.declaresXCTestCaseSubclass(inherited),
      "Detector must NOT consider a `: PalaceWiringTestCase` extension as a direct XCTestCase subclass"
    )
    XCTAssertTrue(
      Self.declaresTestCaseBaseSubclass(inherited),
      "Detector must recognise inheritance from a `*TestCase` base other than XCTestCase"
    )
    // The combined trigger (XCTestCase-subclass AND polluter AND no
    // tearDown) cannot fire because the first leg is false.
    XCTAssertTrue(
      Self.containsPolluter(inherited),
      "Synthetic fixture mentions a polluter (sanity)"
    )
  }

  /// Synthetic compliant case: declares `: XCTestCase` AND mentions a
  /// polluter, but DOES declare a tearDown. Detector MUST NOT flag it.
  func testLintAcceptsExplicitTearDown() {
    let compliant = """
    import XCTest

    @MainActor
    final class SyntheticCompliantTests: XCTestCase {
        var manager: AccountsManager?

        override func setUpWithError() throws {
            manager = AccountsManager()
        }

        override func tearDownWithError() throws {
            manager = nil
            try super.tearDownWithError()
        }

        func testFoo() {
            XCTAssertNotNil(manager)
        }
    }
    """
    XCTAssertTrue(
      Self.declaresXCTestCaseSubclass(compliant),
      "Sanity: compliant fixture declares XCTestCase subclass"
    )
    XCTAssertTrue(
      Self.containsPolluter(compliant),
      "Sanity: compliant fixture mentions a polluter"
    )
    XCTAssertTrue(
      Self.hasTearDownOverride(compliant),
      "Detector must recognise `override func tearDownWithError()` as compliance"
    )
  }

  /// Self-test: the baseline file loads at static init time and parses
  /// at least one entry. If the resolver path is wrong, every legacy
  /// file in the baseline would silently lint as a violator — a louder
  /// failure than letting them pass.
  func testBaselineFileIsLoaded() {
    XCTAssertFalse(
      Self.baselinedFiles.isEmpty,
      "Expected E-teardown-baseline.txt to load with at least one entry"
    )
    XCTAssertLessThan(
      Self.baselinedFiles.count, 200,
      "Baseline is unexpectedly large — verify the file was not corrupted or accidentally appended to"
    )
    // Spot-check: at least one well-known baseline entry resolves.
    XCTAssertTrue(
      Self.baselinedFiles.contains("PalaceTests/AppInfrastructure/AppContainerTests.swift")
        || Self.baselinedFiles.contains("PalaceTests/CoverageGapTests3.swift"),
      "Baseline should include a known XCTestCase-derived polluter-touching file"
    )
  }
}
