//
//  OnboardingSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class OnboardingSnapshotTests: XCTestCase {
  
  // MARK: - TPPOnboardingView
  
  func testOnboardingView() {
    let view = TPPOnboardingView { }
      .frame(width: 390, height: 844)
    
    assertMultiDeviceSnapshot(of: view)
  }
  
  // MARK: - TPPPagerDotsView
  
  func testPagerDotsView_firstPage() {
    let view = TPPPagerDotsView(count: 3, currentIndex: .constant(0))
      .frame(width: 100, height: 20)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 20)
  }
  
  func testPagerDotsView_middlePage() {
    let view = TPPPagerDotsView(count: 3, currentIndex: .constant(1))
      .frame(width: 100, height: 20)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 20)
  }
  
  func testPagerDotsView_lastPage() {
    let view = TPPPagerDotsView(count: 3, currentIndex: .constant(2))
      .frame(width: 100, height: 20)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 100, height: 20)
  }
  
  // MARK: - Accessibility
  
  func testOnboardingAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Onboarding.view.isEmpty)
    XCTAssertFalse(AccessibilityID.Onboarding.closeButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Onboarding.pagerDots.isEmpty)
  }
}
