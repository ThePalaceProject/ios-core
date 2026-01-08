//
//  SnapshotTestConfiguration.swift
//  PalaceTests
//
//  Shared configuration for snapshot testing across multiple device types.
//

import XCTest
import SwiftUI
import SnapshotTesting

/// Device configurations for snapshot testing.
/// These match the simulators available on GitHub Actions macos-14 runners.
enum SnapshotDevice: String, CaseIterable {
  case iPhoneSE = "iPhone SE"
  case iPhone14 = "iPhone 14"
  
  var config: ViewImageConfig {
    switch self {
    case .iPhoneSE:
      return .iPhoneSe
    case .iPhone14:
      return .iPhone13  // iPhone 14 uses same dimensions as iPhone 13
    }
  }
  
  var displayName: String {
    rawValue
  }
}

/// Check if running in CI environment
/// BUILD_CONTEXT is set by our workflow, GITHUB_ACTIONS is set by GitHub
private var isRunningInCI: Bool {
  ProcessInfo.processInfo.environment["BUILD_CONTEXT"] == "ci" ||
  ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
  ProcessInfo.processInfo.environment["CI"] == "true"
}

/// Extension to run snapshot tests across multiple devices
extension XCTestCase {
  
  /// Assert snapshot across all configured devices
  /// - Note: Skipped in CI to reduce test time. Run locally to verify UI.
  @MainActor
  func assertMultiDeviceSnapshot<V: View>(
    of view: V,
    named name: String? = nil,
    record: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    // Skip snapshot tests in CI - they're slow and should be verified locally
    guard !isRunningInCI else {
      return
    }
    
    let shouldRecord = record || ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil
    
    for device in SnapshotDevice.allCases {
      let snapshotName = name.map { "\($0)_\(device.rawValue)" } ?? device.rawValue
      
      assertSnapshot(
        of: view,
        as: .image(layout: .device(config: device.config)),
        named: snapshotName,
        record: shouldRecord,
        file: file,
        testName: testName,
        line: line
      )
    }
  }
  
  /// Assert snapshot for a single device (for tests that don't need multi-device)
  /// - Note: Skipped in CI to reduce test time. Run locally to verify UI.
  @MainActor
  func assertDeviceSnapshot<V: View>(
    of view: V,
    on device: SnapshotDevice = .iPhoneSE,
    named name: String? = nil,
    record: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    // Skip snapshot tests in CI
    guard !isRunningInCI else {
      return
    }
    
    let shouldRecord = record || ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil
    let snapshotName = name.map { "\($0)_\(device.rawValue)" } ?? device.rawValue
    
    assertSnapshot(
      of: view,
      as: .image(layout: .device(config: device.config)),
      named: snapshotName,
      record: shouldRecord,
      file: file,
      testName: testName,
      line: line
    )
  }
  
  /// Assert snapshot with fixed size (device-independent, for small components)
  /// - Note: Skipped in CI to reduce test time. Run locally to verify UI.
  @MainActor
  func assertFixedSizeSnapshot<V: View>(
    of view: V,
    width: CGFloat,
    height: CGFloat,
    userInterfaceStyle: UIUserInterfaceStyle = .light,
    named name: String? = nil,
    record: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    // Skip snapshot tests in CI
    guard !isRunningInCI else {
      return
    }
    
    let shouldRecord = record || ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil
    
    let traits = UITraitCollection(traitsFrom: [
      UITraitCollection(displayScale: 2.0),
      UITraitCollection(userInterfaceStyle: userInterfaceStyle)
    ])
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: width, height: height), traits: traits),
      named: name,
      record: shouldRecord,
      file: file,
      testName: testName,
      line: line
    )
  }
}
