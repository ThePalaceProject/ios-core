//
//  MockIsolationLintTests.swift
//  PalaceTests
//
//  Meta-tests that enforce mock-isolation hygiene rules across
//  PalaceTests/. They prevent the class of test-pollution bugs surfaced
//  by F-008 (regression 2026-05-14), where a mock retained `_credentials`
//  state between tests because its shared singleton had no
//  `resetShared()` and was never zeroed in tearDown.
//
//  Rules (one XCTest per rule, so failures stay readable):
//
//   1. Shared-singleton rule — any file declaring `static var shared`
//      or `static let shared` MUST also declare `static func resetShared()`.
//   2. Cancellables rule — any file storing
//      `var cancellables: Set<AnyCancellable>` MUST tear them down via
//      one of: `func reset()`, `func removeAll()`, or `tearDown` that
//      contains `cancellables.removeAll()`. Inheritance from a
//      `*TestCase` base class (e.g. `PalaceWiringTestCase`) is treated
//      as compliant — the base class drains the bag in its own tearDown.
//   3. Observer rule — any file calling
//      `NotificationCenter.default.addObserver` MUST also call
//      `removeObserver` somewhere in the same file (typically in
//      `deinit` or `cleanup()`).
//
//  Implementation deliberately uses plain substring/regex matching on
//  raw file text — no SwiftSyntax. The rules are narrow, and a missed
//  edge case here is a much smaller cost than a swift-syntax dependency.
//
//  Scope (swarm_47883816 work package E): walks ALL of `PalaceTests/`
//  recursively, minus:
//   - The `MetaTests/` directory itself (lint files contain banned
//     substrings as fixtures — would self-trigger).
//   - The `Support/` files that ARE the reset infrastructure
//     (`SingletonResetRegistry`, `TPPUserAccountTestFactory`'s
//     nested `Tracker`) — they implement the reset surface they would
//     otherwise be linted for.
//
//  The PalaceAudiobookToolkit submodule is a separate project and
//  intentionally out of scope.
//

import Foundation
import XCTest

final class MockIsolationLintTests: XCTestCase {

  // MARK: - Resolution

  /// `PalaceTests/` resolved relative to this file's location so the test
  /// works in every checkout (no env vars, no CI-specific paths).
  ///
  /// **swarm_47883816 work package E** broadened this from `Mocks/` to
  /// the entire `PalaceTests/` tree. The 3 hygiene rules apply equally
  /// to mocks AND to test classes — the F-008 leak class was rooted in
  /// a mock, but the same pattern (stateful Combine sinks, observer
  /// retention, shared singletons without reset) exists in test classes
  /// that drive ViewModels and services.
  private static let palaceTestsRoot: URL = {
    URL(fileURLWithPath: #file)
      .deletingLastPathComponent()  // MetaTests/
      .deletingLastPathComponent()  // PalaceTests/
  }()

  /// Path SUFFIXES (relative to repo root, ending at filename) explicitly
  /// exempt from the singleton-without-resetShared rule. Each entry must
  /// have a documented rationale.
  ///
  /// These are exempt because the file IS the reset infrastructure that
  /// the rule was written to enforce — linting them for `resetShared()`
  /// would be circular. They're in `Support/`, hand-reviewed, and have
  /// their own reset-correctness tests (see *Tests.swift siblings).
  private static let sharedSingletonExemptSuffixes: [String] = [
    // Process-wide registry of resetters; `shared` is the registry
    // itself, which has its own `reset()` method (not named
    // `resetShared` — the type-level reset isn't applicable, the
    // registry's reset is the instance method that iterates).
    "PalaceTests/Support/SingletonResetRegistry.swift",
    // Nested `Tracker.shared` is a test-only mint counter; the factory's
    // resetter is registered with `SingletonResetRegistry` under the
    // stable name `TPPUserAccountTestFactory.minted`, not via a
    // `static func resetShared`. See file header for rationale.
    "PalaceTests/Support/TPPUserAccountTestFactory.swift",
  ]

  /// All `*.swift` files under `PalaceTests/` (recursive), with the
  /// MetaTests/ directory itself excluded (lint sources contain banned
  /// substrings as fixtures).
  private func palaceTestsSwiftFiles() throws -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: Self.palaceTestsRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      XCTFail("Could not enumerate \(Self.palaceTestsRoot.path) — is the PalaceTests directory present?")
      return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "swift" else { continue }
      let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
      guard isRegular else { continue }
      // Skip the MetaTests directory — lint sources contain banned
      // substrings in string literals and synthetic-violator fixtures.
      if url.path.contains("/PalaceTests/MetaTests/") { continue }
      files.append(url)
    }
    return files
  }

  /// Read a file as UTF-8, returning nil on failure (which fails the test).
  private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// True if the file path ends with one of the documented
  /// shared-singleton exemption suffixes.
  private func isSharedSingletonExempt(_ url: URL) -> Bool {
    let path = url.path
    return Self.sharedSingletonExemptSuffixes.contains { path.hasSuffix($0) }
  }

  /// Cheap regex predicate that returns `false` if the pattern is malformed
  /// (we'd rather not throw out of every rule call site).
  private func regexMatches(_ src: String, pattern: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    return re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil
  }

  /// True if the file declares a class inheriting from anything whose
  /// name ends in `TestCase` (e.g. `PalaceWiringTestCase`). The shared
  /// `tearDown` / `cancellables.removeAll()` lives on the base, so
  /// subclasses are compliant by inheritance.
  ///
  /// Detection is regex-level: matches
  ///   class Foo: BarTestCase {
  ///   class Foo: BarTestCase, Bar {
  ///   final class Foo: BarTestCase {
  /// Comment lines starting with `//` are filtered to avoid false
  /// positives in doc comments.
  private func inheritsFromTestCaseBase(_ src: String) -> Bool {
    // Strip whole-line comments first so doc references don't match.
    let code = src
      .components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    // `class <Name>: <Base>TestCase` where Base is any identifier chunk.
    let pattern = #"\bclass\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*[A-Za-z_][A-Za-z0-9_]*TestCase\b"#
    return regexMatches(code, pattern: pattern)
  }

  // MARK: - Rule 1: shared singleton must declare resetShared()

  func testEveryFileWithSharedSingleton_hasResetShared() throws {
    let files = try palaceTestsSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No PalaceTests files discovered at \(Self.palaceTestsRoot.path)")

    // Matches:
    //   static var shared
    //   static let shared
    //   private static var shared
    //   fileprivate static let shared
    // …regardless of access modifiers preceding `static`.
    let sharedPattern = #"(?m)^[^/\n]*\bstatic\s+(var|let)\s+shared\b"#
    // Matches `static func resetShared(` (any access modifier OK).
    let resetPattern = #"\bstatic\s+func\s+resetShared\s*\("#

    var violators: [String] = []
    for url in files {
      if isSharedSingletonExempt(url) { continue }
      guard let src = contents(of: url) else {
        XCTFail("Could not read \(url.lastPathComponent)")
        continue
      }
      guard regexMatches(src, pattern: sharedPattern) else { continue }
      if !regexMatches(src, pattern: resetPattern) {
        violators.append(url.lastPathComponent)
      }
    }

    XCTAssertTrue(
      violators.isEmpty,
      """
      Files with `static var/let shared` MUST declare `static func resetShared()`. \
      Without a reset, state leaks between tests (F-008 regression class). Violators: \
      \(violators.sorted())
      """
    )
  }

  // MARK: - Rule 2: cancellables must be torn down

  func testEveryFileWithCancellables_tearsThemDown() throws {
    let files = try palaceTestsSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No PalaceTests files discovered at \(Self.palaceTestsRoot.path)")

    // Matches `var cancellables: Set<AnyCancellable>` (any access modifier;
    // optional `= []` initializer; also allows trailing whitespace).
    // Optional `!` between identifier and colon (for forced-unwrap form
    // common in test fixtures: `var cancellables: Set<AnyCancellable>!`).
    let cancellablesPattern = #"\bvar\s+cancellables\s*:\s*Set\s*<\s*AnyCancellable\s*>"#

    var violators: [String] = []
    for url in files {
      guard let src = contents(of: url) else {
        XCTFail("Could not read \(url.lastPathComponent)")
        continue
      }
      guard regexMatches(src, pattern: cancellablesPattern) else { continue }

      // Acceptable teardown shapes:
      //   func reset() with cancellables zeroing in the file
      //   func removeAll()              — collection-flavored teardown
      //   override func tearDown(...)   — XCTest-style, containing
      //                                   cancellables.removeAll() or = []
      //   class Foo: PalaceWiringTestCase / class Foo: SomeTestCase
      //     — base class drains cancellables on tearDown
      let hasReset = src.range(of: #"\bfunc\s+reset\s*\("#, options: .regularExpression) != nil
      let hasRemoveAll = src.range(of: #"\bfunc\s+removeAll\s*\("#, options: .regularExpression) != nil
      let hasTearDown = src.range(of: #"\bfunc\s+tearDown\s*\("#, options: .regularExpression) != nil
      let zeroesOutright = src.contains("cancellables.removeAll()") || src.contains("cancellables = []")
      let hasTearDownWithRemoveAll = hasTearDown && zeroesOutright
      let inheritsTestCase = inheritsFromTestCaseBase(src)

      // Treat the file as compliant if ANY of:
      //   - a `func reset()` exists AND the file zeroes cancellables, OR
      //   - a `func removeAll()` exists, OR
      //   - a tearDown contains `cancellables.removeAll()`, OR
      //   - the file zeroes the set unconditionally somewhere (e.g. deinit), OR
      //   - the class inherits from a `*TestCase` base (which drains on its tearDown).
      let compliant = (hasReset && zeroesOutright)
        || hasRemoveAll
        || hasTearDownWithRemoveAll
        || zeroesOutright
        || inheritsTestCase

      if !compliant {
        violators.append(url.lastPathComponent)
      }
    }

    XCTAssertTrue(
      violators.isEmpty,
      """
      Files storing `var cancellables: Set<AnyCancellable>` MUST tear them down \
      via `func reset()` (with `cancellables.removeAll()` in body), \
      `func removeAll()`, a `tearDown` override containing \
      `cancellables.removeAll()`, OR inherit from a `*TestCase` base class \
      (e.g. `PalaceWiringTestCase`) that drains the bag on tearDown. \
      Violators: \(violators.sorted())
      """
    )
  }

  // MARK: - Rule 3: NotificationCenter observers must be removed

  func testEveryFileWithNotificationObserver_removesIt() throws {
    let files = try palaceTestsSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No PalaceTests files discovered at \(Self.palaceTestsRoot.path)")

    var violators: [String] = []
    for url in files {
      guard let src = contents(of: url) else {
        XCTFail("Could not read \(url.lastPathComponent)")
        continue
      }
      // Narrow trigger — we only care about NotificationCenter observers,
      // not e.g. arbitrary `addObserver` methods on custom types.
      guard src.contains("NotificationCenter.default.addObserver") else { continue }
      // Acceptable: any `removeObserver` call site in the same file.
      // Typical placements: `deinit`, `cleanup()`, or per-token removals.
      guard src.contains("removeObserver") else {
        violators.append(url.lastPathComponent)
        continue
      }
    }

    XCTAssertTrue(
      violators.isEmpty,
      """
      Files calling `NotificationCenter.default.addObserver` MUST also call \
      `removeObserver` in the same file (typically in `deinit` or `cleanup()`). \
      Violators: \(violators.sorted())
      """
    )
  }

  // MARK: - Rule 4: lint self-tests (proves the detectors actually fire)

  /// Feeds the cancellables-rule detector a synthetic source whose only
  /// teardown comes via inheritance from a `*TestCase` base. The lint
  /// must accept it. Without this self-test, a regex regression in
  /// `inheritsFromTestCaseBase` would silently make `*TestCase`
  /// subclasses lint as violators.
  func testLintAcceptsInheritedTearDown() {
    let synthetic = """
    import Foundation
    import Combine
    import XCTest

    final class SyntheticInheritsTests: PalaceWiringTestCase {
        var cancellables: Set<AnyCancellable> = []
        func testSomething() {
            cancellables.insert(Empty<Int, Never>().sink { _ in })
        }
    }
    """
    XCTAssertTrue(
      inheritsFromTestCaseBase(synthetic),
      "Detector must recognise inheritance from `*TestCase` bases"
    )
  }

  /// Feeds the cancellables-rule detector a synthetic source whose
  /// teardown chain explicitly zeroes the bag. The detector's `zeroes
  /// outright` branch must accept it.
  func testLintCatchesSyntheticViolator() {
    // Violator: declares `cancellables` but has no teardown of any kind
    // and no `*TestCase` inheritance.
    let violator = """
    import Foundation
    import Combine

    final class SyntheticViolator {
        var cancellables: Set<AnyCancellable> = []
    }
    """
    // Re-run the cancellables-rule predicates inline so the test is
    // self-contained (doesn't need to construct violator files on disk).
    let cancellablesPattern = #"\bvar\s+cancellables\s*:\s*Set\s*<\s*AnyCancellable\s*>"#
    XCTAssertTrue(
      regexMatches(violator, pattern: cancellablesPattern),
      "Detector must spot `var cancellables: Set<AnyCancellable>`"
    )

    let hasReset = violator.range(of: #"\bfunc\s+reset\s*\("#, options: .regularExpression) != nil
    let hasRemoveAll = violator.range(of: #"\bfunc\s+removeAll\s*\("#, options: .regularExpression) != nil
    let hasTearDown = violator.range(of: #"\bfunc\s+tearDown\s*\("#, options: .regularExpression) != nil
    let zeroesOutright = violator.contains("cancellables.removeAll()") || violator.contains("cancellables = []")
    let inheritsTestCase = inheritsFromTestCaseBase(violator)
    let compliant = (hasReset && zeroesOutright)
      || hasRemoveAll
      || (hasTearDown && zeroesOutright)
      || zeroesOutright
      || inheritsTestCase
    XCTAssertFalse(
      compliant,
      "Detector must mark a bare-cancellables-no-teardown file as a violator"
    )
  }
}
