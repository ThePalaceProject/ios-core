//
//  SettingsSnapshotTests.swift
//  PalaceTests
//
//  Visual regression tests for Settings screens.
//  Replaces Appium: Settings.feature
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
  
  // MARK: - TPPSettingsView Snapshots
  
  func testSettingsView_mainScreen() {
    guard canRecordSnapshots else { return }
    
    let view = TPPSettingsView()
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AccountDetailView Snapshots
  
  func testAccountDetailView_signedOut() {
    guard canRecordSnapshots else { return }
    
    // Use current account ID if available
    guard let accountID = AccountsManager.shared.currentAccountId else {
      // Skip test if no account is set up
      return
    }
    
    let view = AccountDetailView(libraryAccountID: accountID)
      .frame(width: 390, height: 600)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AdvancedSettingsView Snapshots
  
  func testAdvancedSettingsView() {
    guard canRecordSnapshots else { return }
    
    // Use current account ID if available
    guard let accountID = AccountsManager.shared.currentAccountId else {
      // Skip test if no account is set up
      return
    }
    
    let view = AdvancedSettingsView(accountID: accountID)
      .frame(width: 390, height: 400)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - EULAView Snapshots
  
  func testEULAView() {
    guard canRecordSnapshots else { return }
    
    let view = EULAView()
      .frame(width: 390, height: 600)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Settings Accessibility
  
  func testSettingsAccessibilityIdentifiers() {
    // Verify settings-related accessibility identifiers exist
    XCTAssertFalse(AccessibilityID.Settings.aboutPalaceButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.manageLibrariesButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signInButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signOutButton.isEmpty)
  }
}
