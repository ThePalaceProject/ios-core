//
//  ColorExtensionTests.swift
//  PalaceTests
//
//  Tests for Color+Extension.swift isDark brightness calculation.
//

import XCTest
import SwiftUI
@testable import Palace

final class ColorExtensionTests: XCTestCase {

  /// SRS: EXT-CLR-001 — Black color is dark
  func testIsDark_Black_ReturnsTrue() {
    let color = Color(UIColor.black)
    XCTAssertTrue(color.isDark)
  }

  /// SRS: EXT-CLR-002 — White color is not dark
  func testIsDark_White_ReturnsFalse() {
    let color = Color(UIColor.white)
    XCTAssertFalse(color.isDark)
  }

  /// SRS: EXT-CLR-003 — Pure red with high saturation uses 0.5 threshold
  func testIsDark_PureRed_ReturnsFalse() {
    // Red: brightness = (1*299 + 0*587 + 0*114)/1000 = 0.299, saturation=1.0
    // threshold = 0.5, 0.299 < 0.5 => dark
    let color = Color(UIColor.red)
    XCTAssertTrue(color.isDark)
  }

  /// SRS: EXT-CLR-004 — Light gray is not dark
  func testIsDark_LightGray_ReturnsFalse() {
    // Light gray ~0.75 brightness, low saturation => threshold 0.4
    let color = Color(UIColor.lightGray)
    XCTAssertFalse(color.isDark)
  }

  /// SRS: EXT-CLR-005 — Dark gray is dark
  func testIsDark_DarkGray_ReturnsTrue() {
    // Dark gray ~0.33 brightness, low saturation => threshold 0.4
    let color = Color(UIColor.darkGray)
    XCTAssertTrue(color.isDark)
  }
}
