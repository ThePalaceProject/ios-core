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
  
  private var canRecordSnapshots: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }
  
  // MARK: - TPPSettingsView
  
  func testSettingsView_mainScreen() {
    guard canRecordSnapshots else { return }
    
    let view = TPPSettingsView()
    assertScreenSnapshot(of: view)
  }
  
  // MARK: - AccountDetailSkeletonView
  
  func testAccountDetailSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = AccountDetailSkeletonView()
      .background(Color(UIColor.systemBackground))
    
    assertFixedSnapshot(of: view, height: 500)
  }
  
  // MARK: - ActionButtonView
  
  func testActionButtonView_normal() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: false,
      action: {}
    )
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertFixedSnapshot(of: view, width: 350, height: 80)
  }
  
  func testActionButtonView_loading() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: true,
      action: {}
    )
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertFixedSnapshot(of: view, width: 350, height: 80)
  }
  
  func testActionButtonView_darkMode() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Settings.signOut,
      isLoading: false,
      action: {}
    )
    .padding()
    .background(Color.black)
    
    assertFixedSnapshot(of: view, width: 350, height: 80, darkMode: true)
  }
  
  // MARK: - SectionSeparator
  
  func testSectionSeparator() {
    guard canRecordSnapshots else { return }
    
    let view = SectionSeparator()
      .padding(.vertical, 20)
      .background(Color(UIColor.systemBackground))
    
    assertFixedSnapshot(of: view, width: 350, height: 60)
  }
  
  // MARK: - AccountDetailView
  
  func testAccountDetailView_signedOut() {
    guard canRecordSnapshots else { return }
    
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AccountDetailView(libraryAccountID: accountID)
    assertFixedSnapshot(of: view, height: 700)
  }
  
  // MARK: - AdvancedSettingsView
  
  func testAdvancedSettingsView() {
    guard canRecordSnapshots else { return }
    
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AdvancedSettingsView(accountID: accountID)
    assertFixedSnapshot(of: view, height: 500)
  }
  
  
  // MARK: - Accessibility
  
  func testSettingsAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Settings.aboutPalaceButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.manageLibrariesButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signInButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signOutButton.isEmpty)
  }
}
