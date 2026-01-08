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

/// Extension to run snapshot tests across multiple devices
extension XCTestCase {
  
  /// Assert snapshot across all configured devices
  /// - Parameters:
  ///   - view: The SwiftUI view to snapshot
  ///   - name: Optional custom name for the snapshot
  ///   - record: Whether to record new reference images
  ///   - file: Source file (auto-captured)
  ///   - testName: Test function name (auto-captured)
  ///   - line: Source line (auto-captured)
  @MainActor
  func assertMultiDeviceSnapshot<V: View>(
    of view: V,
    named name: String? = nil,
    record: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
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
  /// - Parameters:
  ///   - view: The SwiftUI view to snapshot
  ///   - device: The device configuration to use
  ///   - name: Optional custom name for the snapshot
  ///   - record: Whether to record new reference images
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
  /// - Parameters:
  ///   - view: The SwiftUI view to snapshot
  ///   - size: The fixed size for the snapshot
  ///   - name: Optional custom name for the snapshot
  ///   - record: Whether to record new reference images
  @MainActor
  func assertFixedSizeSnapshot<V: View>(
    of view: V,
    size: CGSize,
    named name: String? = nil,
    record: Bool = false,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
  ) {
    let shouldRecord = record || ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: size.width, height: size.height)),
      named: name,
      record: shouldRecord,
      file: file,
      testName: testName,
      line: line
    )
  }
}
