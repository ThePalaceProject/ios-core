// MarksFixture.swift
//
// Loads simdrive observation fixtures (.specterqa/fixtures/baselines/<version>/<flow>/<step>.json)
// and provides assertions for behavior captured at the on-screen-text level.
//
// See .specterqa/fixtures/README.md for the schema and rationale. Short version:
// each fixture is a structured snapshot of every visible text region at a known
// step in a flow. Tests assert what the user sees rather than what the
// ViewModel privately holds — closes the F-001-class mutation testing gap.

import Foundation
import XCTest

/// A single OCR-detected text region from a simdrive `observe` response.
struct FixtureMark: Decodable {
  let id: Int
  /// `[x, y, width, height]` in pixels.
  let bbox: [Int]
  /// `[x, y]` center in pixels.
  let center: [Int]
  let text: String
  let confidence: Double

  var centerX: Int { center[0] }
  var centerY: Int { center[1] }
}

/// A loaded fixture. Use the static `load(_:version:)` factory.
struct MarksFixture: Decodable {
  let fixture: String
  let version: String
  let build: String
  let device: String
  let os: String
  let udid: String
  let captured_at: String
  let screen_size: [Int]
  let screenshot_relpath: String
  let marks: [FixtureMark]

  // MARK: - Loading

  /// Load a fixture by its `<flow>/<step>` id and version.
  /// Searches the test bundle's `.specterqa/fixtures/baselines/<version>/<flow>/<step>.json`.
  /// On miss, falls back to walking up from the test source file to repo root.
  static func load(_ id: String, version: String, file: StaticString = #filePath) throws -> MarksFixture {
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
      throw FixtureError.malformedId(id)
    }
    let (flow, step) = (parts[0], parts[1])

    let url = try resolveFixtureURL(version: version, flow: flow, step: step, sourceFile: file)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(MarksFixture.self, from: data)
  }

  // MARK: - Assertions

  /// First mark whose text is exactly equal (case-insensitive trim) to `text`.
  func firstMark(withText text: String) -> FixtureMark? {
    let target = text.trimmingCharacters(in: .whitespaces).lowercased()
    return marks.first { $0.text.trimmingCharacters(in: .whitespaces).lowercased() == target }
  }

  /// First mark whose text contains `text` (case-insensitive).
  func firstMark(containing text: String) -> FixtureMark? {
    let target = text.lowercased()
    return marks.first { $0.text.lowercased().contains(target) }
  }

  /// Assert that `text` is present and its center y is within `tolerancePx` of `expectedY`.
  /// Use this to lock in vertical positions of CTAs (Borrow, Read, Sign In) where a
  /// regression-induced layout shift would change the y by more than expected jitter.
  func assertText(
    _ text: String,
    nearY expectedY: Int,
    tolerancePx: Int = 20,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let mark = firstMark(withText: text) ?? firstMark(containing: text) else {
      XCTFail("Expected text '\(text)' not found in fixture '\(fixture)' (\(version)). Visible: \(marks.map(\.text).joined(separator: " | "))",
              file: file, line: line)
      return
    }
    let delta = abs(mark.centerY - expectedY)
    if delta > tolerancePx {
      XCTFail("Text '\(text)' found at y=\(mark.centerY) but expected y≈\(expectedY) (Δ=\(delta), tolerance=\(tolerancePx)) in '\(fixture)' (\(version))",
              file: file, line: line)
    }
  }

  /// Assert that `text` appears anywhere in the fixture (no position constraint).
  func assertContainsText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    if firstMark(containing: text) == nil {
      XCTFail("Expected text '\(text)' not found in fixture '\(fixture)' (\(version))",
              file: file, line: line)
    }
  }

  /// Assert that `text` does NOT appear anywhere — used for negative behavior
  /// (e.g., 'Borrow' must be absent after a successful borrow; 'Sign In' must be
  /// absent on the anonymous flow).
  func assertNoText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    if let hit = firstMark(containing: text) {
      XCTFail("Text '\(text)' should be absent but was found in fixture '\(fixture)' (\(version)) at y=\(hit.centerY): '\(hit.text)'",
              file: file, line: line)
    }
  }

  /// Assert all of `texts` are present in the order they appear.
  /// Useful for tab bars, lane order, etc.
  func assertOrderedTexts(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
    let resolved = texts.compactMap { firstMark(containing: $0) }
    if resolved.count != texts.count {
      let missing = texts.enumerated().filter { i, _ in i >= resolved.count }.map(\.1)
      XCTFail("Expected ordered texts \(texts), missing: \(missing) in '\(fixture)' (\(version))",
              file: file, line: line)
      return
    }
    let xs = resolved.map(\.centerX)
    let ys = resolved.map(\.centerY)
    let isOrderedByY = zip(ys, ys.dropFirst()).allSatisfy { $0 <= $1 + 5 }
    let isOrderedByX = zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 5 }
    if !(isOrderedByY || isOrderedByX) {
      XCTFail("Texts \(texts) found but not in y- or x-order in '\(fixture)' (\(version)). Centers: \(zip(xs, ys).map { "(\($0), \($1))" })",
              file: file, line: line)
    }
  }

  /// Compare two fixtures (typically baseline vs candidate). Returns a list of marks
  /// that moved more than `tolerancePx` between the two. Used by marks-diff.py for
  /// auto-generated findings, but also handy in tests as
  /// `XCTAssertTrue(baseline.movedMarks(vs: candidate).isEmpty)` for a strict check.
  struct MarkMovement {
    let text: String
    let baselineCenter: (Int, Int)
    let candidateCenter: (Int, Int)
    var deltaX: Int { candidateCenter.0 - baselineCenter.0 }
    var deltaY: Int { candidateCenter.1 - baselineCenter.1 }
  }

  func movedMarks(vs other: MarksFixture, tolerancePx: Int = 30) -> [MarkMovement] {
    var movements: [MarkMovement] = []
    for mark in marks {
      guard let match = other.firstMark(withText: mark.text) else { continue }
      let dx = abs(mark.centerX - match.centerX)
      let dy = abs(mark.centerY - match.centerY)
      if max(dx, dy) > tolerancePx {
        movements.append(.init(
          text: mark.text,
          baselineCenter: (mark.centerX, mark.centerY),
          candidateCenter: (match.centerX, match.centerY)
        ))
      }
    }
    return movements
  }

  // MARK: - URL resolution

  private static func resolveFixtureURL(version: String, flow: String, step: String, sourceFile: StaticString) throws -> URL {
    let relpath = ".specterqa/fixtures/baselines/\(version)/\(flow)/\(step).json"
    let candidates = candidateRoots(sourceFile: sourceFile).map { $0.appendingPathComponent(relpath) }
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    throw FixtureError.notFound(id: "\(flow)/\(step)", version: version, searched: candidates.map(\.path))
  }

  private static func candidateRoots(sourceFile: StaticString) -> [URL] {
    var roots: [URL] = []
    // Walk up from this source file (PalaceTests/VisualRegression/...) to repo root.
    var url = URL(fileURLWithPath: "\(sourceFile)").deletingLastPathComponent()
    for _ in 0..<8 {
      roots.append(url)
      url = url.deletingLastPathComponent()
    }
    // Also try Bundle resource path (when fixtures are copied into the test bundle).
    if let bundleURL = Bundle(for: BundleAnchor.self).resourceURL {
      roots.append(bundleURL)
    }
    return roots
  }

  enum FixtureError: Error, CustomStringConvertible {
    case malformedId(String)
    case notFound(id: String, version: String, searched: [String])

    var description: String {
      switch self {
      case .malformedId(let id):
        return "MarksFixture id must be '<flow>/<step>'; got '\(id)'"
      case .notFound(let id, let version, let searched):
        return "MarksFixture '\(id)' (\(version)) not found. Searched: \(searched.joined(separator: ", "))"
      }
    }
  }

  private final class BundleAnchor {}
}
