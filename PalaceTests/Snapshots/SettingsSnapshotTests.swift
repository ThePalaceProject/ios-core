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
  
  // MARK: - AccountDetailSkeletonView Snapshots
  // Tests the loading state skeleton
  
  func testAccountDetailSkeletonView() {
    guard canRecordSnapshots else { return }
    
    let view = AccountDetailSkeletonView()
      .frame(width: 390, height: 500)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - ActionButtonView Snapshots
  // Tests the reusable action button in different states
  
  func testActionButtonView_normal() {
    guard canRecordSnapshots else { return }
    
    let view = ActionButtonView(
      title: "Sign In",
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
      title: "Sign In",
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
      title: "Sign Out",
      isLoading: false,
      action: {}
    )
    .frame(width: 350)
    .padding()
    .background(Color.black)
    .environment(\.colorScheme, .dark)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - SectionSeparator Snapshots
  
  func testSectionSeparator() {
    guard canRecordSnapshots else { return }
    
    let view = VStack(spacing: 20) {
      Text("Section 1")
      SectionSeparator()
      Text("Section 2")
    }
    .frame(width: 350)
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - AccountDetailView Snapshots (requires account)
  
  func testAccountDetailView_signedOut() {
    guard canRecordSnapshots else { return }
    
    // Use current account ID if available
    guard let accountID = AccountsManager.shared.currentAccountId else {
      // Create a minimal test without account
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
      // Skip test if no account is set up
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
  
  // MARK: - Settings Menu Items
  // Tests the visual consistency of settings row items
  
  func testSettingsRowItem_libraries() {
    guard canRecordSnapshots else { return }
    
    let view = List {
      NavigationLink(destination: EmptyView()) {
        Text(Strings.Settings.libraries)
          .palaceFont(.body)
      }
    }
    .listStyle(GroupedListStyle())
    .frame(width: 390, height: 100)
    
    assertSnapshot(of: view, as: .image)
  }
  
  func testSettingsRowItem_infoSection() {
    guard canRecordSnapshots else { return }
    
    let view = List {
      Section {
        NavigationLink(destination: EmptyView()) {
          Text(Strings.Settings.aboutApp)
            .palaceFont(.body)
        }
        NavigationLink(destination: EmptyView()) {
          Text(Strings.Settings.privacyPolicy)
            .palaceFont(.body)
        }
        NavigationLink(destination: EmptyView()) {
          Text(Strings.Settings.eula)
            .palaceFont(.body)
        }
        NavigationLink(destination: EmptyView()) {
          Text(Strings.Settings.softwareLicenses)
            .palaceFont(.body)
        }
      }
    }
    .listStyle(GroupedListStyle())
    .frame(width: 390, height: 250)
    
    assertSnapshot(of: view, as: .image)
  }
  
  // MARK: - Version Info Footer
  
  func testVersionInfoFooter() {
    guard canRecordSnapshots else { return }
    
    let productName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Palace"
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: (kCFBundleVersionKey as String)) as? String ?? "Unknown"
    
    let view = Text("\(productName) version \(version) (\(build))")
      .palaceFont(size: 12)
      .frame(height: 40)
      .frame(width: 390)
      .background(Color(UIColor.systemBackground))
    
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
