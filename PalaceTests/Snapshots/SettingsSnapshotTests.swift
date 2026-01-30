//
//  SettingsSnapshotTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class SettingsSnapshotTests: XCTestCase {
  
  // MARK: - TPPSettingsView
  
  func testSettingsView_mainScreen() {
    let view = TPPSettingsView()
    assertFixedSizeSnapshot(of: view, width: 390, height: 844)
  }
  
  // MARK: - AccountDetailSkeletonView
  
  func testAccountDetailSkeletonView() {
    let view = AccountDetailSkeletonView()
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 390, height: 500)
  }
  
  // MARK: - ActionButtonView
  
  func testActionButtonView_normal() {
    let view = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: false,
      action: {}
    )
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 350, height: 80)
  }
  
  func testActionButtonView_loading() {
    let view = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: true,
      action: {}
    )
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 350, height: 80)
  }
  
  func testActionButtonView_darkMode() {
    let view = ActionButtonView(
      title: Strings.Settings.signOut,
      isLoading: false,
      action: {}
    )
    .padding()
    .background(Color.black)
    
    assertFixedSizeSnapshot(of: view, width: 350, height: 80, userInterfaceStyle: .dark)
  }
  
  // MARK: - SectionSeparator
  
  func testSectionSeparator() {
    let view = SectionSeparator()
      .padding(.vertical, 20)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSizeSnapshot(of: view, width: 350, height: 60)
  }
  
  // MARK: - AccountDetailView
  
  func testAccountDetailView_signedOut() {
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AccountDetailView(libraryAccountID: accountID)
    assertFixedSizeSnapshot(of: view, width: 390, height: 700)
  }
  
  // MARK: - AdvancedSettingsView
  
  func testAdvancedSettingsView() {
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AdvancedSettingsView(accountID: accountID)
    assertFixedSizeSnapshot(of: view, width: 390, height: 500)
  }
  
  
  // MARK: - Accessibility
  
  func testSettingsAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Settings.aboutPalaceButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.manageLibrariesButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signInButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signOutButton.isEmpty)
  }
}
