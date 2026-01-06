//
//  SignInSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for Sign-In related views.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class SignInSnapshotTests: XCTestCase {
  
  private var canRecordSnapshots: Bool {
    ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] != nil || isRecording
  }
  
  override func setUp() {
    super.setUp()
    isRecording = false
  }
  
  // MARK: - Account Detail Skeleton Tests
  
  func testAccountDetailSkeletonView() {
    let skeletonView = AccountDetailSkeletonView()
      .frame(width: 390, height: 600)
      .background(Color(UIColor.systemGroupedBackground))
    
    assertSnapshot(of: skeletonView, as: .image)
  }
  
  func testAccountDetailSkeletonView_darkMode() {
    let skeletonView = AccountDetailSkeletonView()
      .frame(width: 390, height: 600)
      .background(Color(UIColor.systemGroupedBackground))
      .colorScheme(.dark)
    
    assertSnapshot(of: skeletonView, as: .image)
  }
  
  // MARK: - Action Button Tests
  
  func testSignInButton_normal() {
    let buttonView = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: false,
      action: {}
    )
    .frame(width: 200, height: 60)
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: buttonView, as: .image)
  }
  
  func testSignInButton_loading() {
    let buttonView = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: true,
      action: {}
    )
    .frame(width: 200, height: 60)
    .padding()
    .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: buttonView, as: .image)
  }
  
  func testSignInButton_darkMode() {
    let buttonView = ActionButtonView(
      title: Strings.Generic.signin,
      isLoading: false,
      action: {}
    )
    .frame(width: 200, height: 60)
    .padding()
    .background(Color(UIColor.systemBackground))
    .colorScheme(.dark)
    
    assertSnapshot(of: buttonView, as: .image)
  }
  
  // MARK: - Section Separator Tests
  
  func testSectionSeparator() {
    let separatorView = SectionSeparator()
      .frame(width: 390, height: 10)
      .background(Color(UIColor.systemBackground))
    
    assertSnapshot(of: separatorView, as: .image)
  }
}

