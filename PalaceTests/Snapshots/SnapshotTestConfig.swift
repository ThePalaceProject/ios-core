//
//  SnapshotTestConfig.swift
//  PalaceTests
//
//  Shared configuration for snapshot tests to ensure device consistency.
//

import SnapshotTesting
import SwiftUI
import XCTest

/// Shared snapshot testing configuration.
/// All snapshot tests should use these settings to ensure consistency across devices.
enum SnapshotTestConfig {
  
  /// Standard iPhone width for snapshot tests
  static let standardWidth: CGFloat = 390
  
  /// Standard precision for image comparison (1.0 = exact match)
  static let precision: Float = 0.99
  
  /// Perceptual precision for image comparison
  static let perceptualPrecision: Float = 0.98
  
  /// Creates a fixed-size image snapshot strategy.
  /// Using fixed sizes ensures snapshots look the same regardless of simulator device.
  static func imageStrategy(width: CGFloat = standardWidth, height: CGFloat) -> Snapshotting<some View, UIImage> {
    .image(
      precision: precision,
      perceptualPrecision: perceptualPrecision,
      layout: .fixed(width: width, height: height)
    )
  }
  
  /// Standard snapshot assertion with fixed layout.
  /// - Parameters:
  ///   - view: The SwiftUI view to snapshot
  ///   - width: Width of the snapshot (default: 390pt - iPhone 14/15 width)
  ///   - height: Height of the snapshot
  ///   - file: Source file (for error reporting)
  ///   - testName: Test name (for snapshot naming)
  ///   - line: Source line (for error reporting)
  @MainActor
  static func assertSnapshot<V: View>(
    of view: V,
    width: CGFloat = standardWidth,
    height: CGFloat,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    SnapshotTesting.assertSnapshot(
      of: view,
      as: .image(
        precision: precision,
        perceptualPrecision: perceptualPrecision,
        layout: .fixed(width: width, height: height)
      ),
      file: file,
      testName: testName,
      line: line
    )
  }
  
  /// Checks if we're running on a simulator (snapshots only work on simulator)
  static var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
}

