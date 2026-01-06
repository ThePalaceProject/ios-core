//
//  SnapshotTestConfig.swift
//  PalaceTests
//
//  Shared configuration for snapshot tests to ensure device consistency.
//  ALL snapshot tests MUST use these helpers to ensure CI/CD compatibility.
//

import SnapshotTesting
import SwiftUI
import XCTest

/// Shared snapshot testing configuration.
/// Using fixed layouts ensures snapshots are identical on iPhone, iPad, or CI/CD.
enum SnapshotTestConfig {
  
  // MARK: - Standard Sizes
  
  /// Standard iPhone width (iPhone 14/15)
  static let standardWidth: CGFloat = 390
  
  /// Standard iPhone height
  static let standardHeight: CGFloat = 844
  
  /// Standard cell height
  static let cellHeight: CGFloat = 120
  
  /// Standard button height
  static let buttonHeight: CGFloat = 60
  
  // MARK: - Precision
  
  /// Precision for image comparison (0.99 = 99% match required)
  static let precision: Float = 0.99
  
  /// Perceptual precision (allows minor anti-aliasing differences)
  static let perceptualPrecision: Float = 0.98
  
  // MARK: - Environment Check
  
  /// Checks if we're running on a simulator (snapshots only work on simulator)
  static var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - Snapshot Strategies
  
  /// Creates a fixed-size image snapshot strategy.
  /// This ensures the same output regardless of device.
  static func fixedImage(width: CGFloat = standardWidth, height: CGFloat) -> Snapshotting<AnyView, UIImage> {
    .image(
      precision: precision,
      perceptualPrecision: perceptualPrecision,
      layout: .fixed(width: width, height: height),
      traits: UITraitCollection(traitsFrom: [
        UITraitCollection(displayScale: 2.0),
        UITraitCollection(userInterfaceStyle: .light)
      ])
    )
  }
  
  /// Creates a fixed-size dark mode image snapshot strategy.
  static func fixedImageDarkMode(width: CGFloat = standardWidth, height: CGFloat) -> Snapshotting<AnyView, UIImage> {
    .image(
      precision: precision,
      perceptualPrecision: perceptualPrecision,
      layout: .fixed(width: width, height: height),
      traits: UITraitCollection(traitsFrom: [
        UITraitCollection(displayScale: 2.0),
        UITraitCollection(userInterfaceStyle: .dark)
      ])
    )
  }
}

// MARK: - Convenience Extensions

extension XCTestCase {
  
  /// Asserts a snapshot with fixed size, ensuring device-independent results.
  /// - Parameters:
  ///   - view: The SwiftUI view to snapshot
  ///   - width: Fixed width (default: 390 - iPhone width)
  ///   - height: Fixed height
  ///   - darkMode: Use dark mode (default: false)
  @MainActor
  func assertFixedSnapshot<V: View>(
    of view: V,
    width: CGFloat = SnapshotTestConfig.standardWidth,
    height: CGFloat,
    darkMode: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    let wrappedView = AnyView(view)
    let strategy = darkMode 
      ? SnapshotTestConfig.fixedImageDarkMode(width: width, height: height)
      : SnapshotTestConfig.fixedImage(width: width, height: height)
    
    assertSnapshot(
      of: wrappedView,
      as: strategy,
      file: file,
      testName: testName,
      line: line
    )
  }
  
  /// Asserts a cell snapshot (120pt height)
  @MainActor
  func assertCellSnapshot<V: View>(
    of view: V,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    assertFixedSnapshot(
      of: view,
      width: SnapshotTestConfig.standardWidth,
      height: SnapshotTestConfig.cellHeight,
      file: file,
      testName: testName,
      line: line
    )
  }
  
  /// Asserts a full-screen snapshot
  @MainActor
  func assertScreenSnapshot<V: View>(
    of view: V,
    darkMode: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    assertFixedSnapshot(
      of: view,
      width: SnapshotTestConfig.standardWidth,
      height: SnapshotTestConfig.standardHeight,
      darkMode: darkMode,
      file: file,
      testName: testName,
      line: line
    )
  }
}
