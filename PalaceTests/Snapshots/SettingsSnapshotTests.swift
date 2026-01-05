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
    
    // Create a mock account for testing
    let view = AccountDetailView(libraryUUID: AccountsManager.shared.currentAccountId ?? "")
      .frame(width: 390, height: 600)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AdvancedSettingsView Snapshots
  
  func testAdvancedSettingsView() {
    guard canRecordSnapshots else { return }
    
    let view = AdvancedSettingsView()
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
    XCTAssertFalse(AccessibilityID.Settings.aboutButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.librariesButton.isEmpty)
  }
}

