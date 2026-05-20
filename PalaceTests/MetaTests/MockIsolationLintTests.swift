//
//  MockIsolationLintTests.swift
//  PalaceTests
//
//  Meta-tests that enforce mock-isolation hygiene rules across
//  PalaceTests/Mocks/. These rules prevent the class of test-pollution
//  bugs surfaced by F-008 (regression 2026-05-14), where a mock
//  retained `_credentials` state between tests because its shared
//  singleton had no `resetShared()` and was never zeroed in tearDown.
//
//  Rules (one XCTest per rule, so failures stay readable):
//
//   1. Shared-singleton rule — any file declaring `static var shared`
//      or `static let shared` MUST also declare `static func resetShared()`.
//   2. Cancellables rule — any file storing
//      `var cancellables: Set<AnyCancellable>` MUST tear them down via
//      one of: `func reset()`, `func removeAll()`, or `tearDown` that
//      contains `cancellables.removeAll()`.
//   3. Observer rule — any file calling
//      `NotificationCenter.default.addObserver` MUST also call
//      `removeObserver` somewhere in the same file (typically in
//      `deinit` or `cleanup()`).
//
//  Implementation deliberately uses plain substring/regex matching on
//  raw file text — no SwiftSyntax. Mocks are short, the rules are
//  narrow, and a missed edge case here is a much smaller cost than a
//  swift-syntax dependency.
//
//  Scope: PalaceTests/Mocks/ only. The PalaceAudiobookToolkit submodule
//  is a separate project and intentionally out of scope.
//

import Foundation
import XCTest

final class MockIsolationLintTests: XCTestCase {

  // MARK: - Resolution

  /// PalaceTests/Mocks/ resolved relative to this file's location so the
  /// test works in every checkout (no env vars, no CI-specific paths).
  private static let mocksRoot: URL = {
    URL(fileURLWithPath: #file)
      .deletingLastPathComponent()  // MetaTests/
      .deletingLastPathComponent()  // PalaceTests/
      .appendingPathComponent("Mocks")
  }()

  /// All `*.swift` files under `PalaceTests/Mocks/` (recursive).
  /// Skips non-Swift artefacts and dotfiles.
  private func mockSwiftFiles() throws -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: Self.mocksRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      XCTFail("Could not enumerate \(Self.mocksRoot.path) — is the Mocks directory present?")
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

  /// Read a file as UTF-8, returning nil on failure (which fails the test).
  private func contents(of url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Cheap regex predicate that returns `false` if the pattern is malformed
  /// (we'd rather not throw out of every rule call site).
  private func regexMatches(_ src: String, pattern: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    return re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)) != nil
  }

  // MARK: - Rule 1: shared singleton must declare resetShared()

  func testEveryMockWithSharedSingleton_hasResetShared() throws {
    let files = try mockSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No mock files discovered at \(Self.mocksRoot.path)")

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
      Mocks with `static var/let shared` MUST declare `static func resetShared()`. \
      Without a reset, state leaks between tests (F-008 regression class). Violators: \
      \(violators.sorted())
      """
    )
  }

  // MARK: - Rule 2: cancellables must be torn down

  func testEveryMockWithCancellables_tearsThemDown() throws {
    let files = try mockSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No mock files discovered at \(Self.mocksRoot.path)")

    // Matches `var cancellables: Set<AnyCancellable>` (any access modifier;
    // optional `= []` initializer; also allows trailing whitespace).
    let cancellablesPattern = #"\bvar\s+cancellables\s*:\s*Set\s*<\s*AnyCancellable\s*>"#

    var violators: [String] = []
    for url in files {
      guard let src = contents(of: url) else {
        XCTFail("Could not read \(url.lastPathComponent)")
        continue
      }
      guard regexMatches(src, pattern: cancellablesPattern) else { continue }

      // Acceptable teardown shapes:
      //   func reset()                     — common in our mocks
      //   func removeAll()                 — collection-flavored teardown
      //   override func tearDown(...)      — XCTest-style, containing
      //                                       cancellables.removeAll()
      let hasReset = src.range(of: #"\bfunc\s+reset\s*\("#, options: .regularExpression) != nil
      let hasRemoveAll = src.range(of: #"\bfunc\s+removeAll\s*\("#, options: .regularExpression) != nil
      let hasTearDownWithRemoveAll: Bool = {
        // Look for an override of tearDown whose body contains
        // `cancellables.removeAll()`. We don't need a full Swift parser —
        // just require the two substrings to coexist in the same file.
        let hasTearDown = src.range(of: #"\bfunc\s+tearDown\s*\("#, options: .regularExpression) != nil
        let zeroes = src.contains("cancellables.removeAll()") || src.contains("cancellables = []")
        return hasTearDown && zeroes
      }()
      let zeroesOutright = src.contains("cancellables.removeAll()") || src.contains("cancellables = []")

      // Treat the file as compliant if ANY of:
      //   - a `func reset()` exists AND it zeroes cancellables, OR
      //   - a `func removeAll()` exists, OR
      //   - a tearDown contains `cancellables.removeAll()`, OR
      //   - the file zeroes the set unconditionally somewhere (e.g. deinit).
      // To stay simple, we accept any reset() / removeAll() function plus a
      // zeroing call site anywhere in the file.
      let compliant = (hasReset && zeroesOutright)
        || hasRemoveAll
        || hasTearDownWithRemoveAll
        || (hasReset && hasTearDownWithRemoveAll)

      if !compliant {
        violators.append(url.lastPathComponent)
      }
    }

    XCTAssertTrue(
      violators.isEmpty,
      """
      Mocks storing `var cancellables: Set<AnyCancellable>` MUST tear them down \
      via `func reset()` (with `cancellables.removeAll()` in body), \
      `func removeAll()`, or a `tearDown` override containing \
      `cancellables.removeAll()`. Violators: \(violators.sorted())
      """
    )
  }

  // MARK: - Rule 3: NotificationCenter observers must be removed

  func testEveryMockWithNotificationObserver_removesIt() throws {
    let files = try mockSwiftFiles()
    XCTAssertFalse(files.isEmpty, "No mock files discovered at \(Self.mocksRoot.path)")

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
      Mocks calling `NotificationCenter.default.addObserver` MUST also call \
      `removeObserver` in the same file (typically in `deinit` or `cleanup()`). \
      Violators: \(violators.sorted())
      """
    )
  }
}
