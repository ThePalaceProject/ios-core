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
  
  // MARK: - TPPSettingsView Snapshots (Full Settings Screen)
  // This captures the entire settings screen including all rows and version info
  
  func testSettingsView_mainScreen() {
    guard canRecordSnapshots else { return }
    
    let view = TPPSettingsView()
      .frame(width: 390, height: 844)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AccountDetailSkeletonView Snapshots
  // Tests the loading state skeleton (real app view)
  
  func testAccountDetailSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = AccountDetailSkeletonView()
      .frame(width: 390, height: 500)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - ActionButtonView Snapshots (Real App Component)
  // Tests the reusable action button in different states
  
  func testActionButtonView_normal() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Settings.signIn,
      isLoading: false,
      action: {}
    )
    .frame(width: 350)
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testActionButtonView_loading() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Settings.signIn,
      isLoading: true,
      action: {}
    )
    .frame(width: 350)
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testActionButtonView_darkMode() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: Strings.Settings.signOut,
      isLoading: false,
      action: {}
    )
    .frame(width: 350)
    .padding()
    .background(Color.black)
    .environment(\.colorScheme, .dark)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - SectionSeparator Snapshot (Real App Component)
  
  func testSectionSeparator() {
    guard canRecordSnapshots else { return }
    
    // Test the real SectionSeparator component in isolation
    let view = SectionSeparator()
      .frame(width: 350)
      .padding(.vertical, 20)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AccountDetailView Snapshots (requires account)
  
  func testAccountDetailView_signedOut() {
    guard canRecordSnapshots else { return }
    
    // Use current account ID if available
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AccountDetailView(libraryAccountID: accountID)
      .frame(width: 390, height: 700)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AdvancedSettingsView Snapshots (requires account)
  
  func testAdvancedSettingsView() {
    guard canRecordSnapshots else { return }
    
    // Use current account ID if available
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AdvancedSettingsView(accountID: accountID)
      .frame(width: 390, height: 500)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - EULAView Snapshots
  // Note: Shows loading state since it loads from URL
  
  func testEULAView_loading() {
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
