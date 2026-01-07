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
  
  // Fixed layout traits for consistent snapshots across devices
  private var fixedTraits: UITraitCollection {
    UITraitCollection(traitsFrom: [
      UITraitCollection(displayScale: 2.0),
      UITraitCollection(userInterfaceStyle: .light)
    ])
  }
  
  private var darkModeTraits: UITraitCollection {
    UITraitCollection(traitsFrom: [
      UITraitCollection(displayScale: 2.0),
      UITraitCollection(userInterfaceStyle: .dark)
    ])
  }
  
  // MARK: - TPPSettingsView
  
  func testSettingsView_mainScreen() {
    guard canRecordSnapshots else { return }
    
    let view = TPPSettingsView()
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 844), traits: fixedTraits)
    )
  }
  
  // MARK: - AccountDetailSkeletonView
  
  func testAccountDetailSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = AccountDetailSkeletonView()
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 500), traits: fixedTraits)
    )
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
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 350, height: 80), traits: fixedTraits)
    )
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
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 350, height: 80), traits: fixedTraits)
    )
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
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 350, height: 80), traits: darkModeTraits)
    )
  }
  
  // MARK: - SectionSeparator
  
  func testSectionSeparator() {
    guard canRecordSnapshots else { return }
    
    let view = SectionSeparator()
      .padding(.vertical, 20)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 350, height: 60), traits: fixedTraits)
    )
  }
  
  // MARK: - AccountDetailView
  
  func testAccountDetailView_signedOut() {
    guard canRecordSnapshots else { return }
    
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AccountDetailView(libraryAccountID: accountID)
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 700), traits: fixedTraits)
    )
  }
  
  // MARK: - AdvancedSettingsView
  
  func testAdvancedSettingsView() {
    guard canRecordSnapshots else { return }
    
    guard let accountID = AccountsManager.shared.currentAccountId else {
      XCTAssertTrue(true, "Skipped - no account configured")
      return
    }
    
    let view = AdvancedSettingsView(accountID: accountID)
    assertSnapshot(
      of: view,
      as: .image(layout: .fixed(width: 390, height: 500), traits: fixedTraits)
    )
  }
  
  
  // MARK: - Accessibility
  
  func testSettingsAccessibilityIdentifiers() {
    XCTAssertFalse(AccessibilityID.Settings.aboutPalaceButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.manageLibrariesButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signInButton.isEmpty)
    XCTAssertFalse(AccessibilityID.Settings.signOutButton.isEmpty)
  }
}
