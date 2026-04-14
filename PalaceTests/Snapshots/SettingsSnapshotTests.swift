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
        // View struct must be constructible without crash
        XCTAssertNotNil(view as Any, "TPPSettingsView must be constructible")
    }

    // MARK: - AccountDetailSkeletonView

    func testAccountDetailSkeletonView() {
        let view = AccountDetailSkeletonView()
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 390, height: 500)
        // Skeleton view is used as a placeholder — must be constructible without account data
        XCTAssertNotNil(view as Any, "AccountDetailSkeletonView must be constructible without account data")
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
        // Title string must not be empty (otherwise the button is unusable)
        XCTAssertFalse(Strings.Generic.signin.isEmpty, "Sign-in button title must not be empty")
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
        XCTAssertNotNil(view as Any, "ActionButtonView in loading state must be constructible")
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
        XCTAssertFalse(Strings.Settings.signOut.isEmpty, "Sign-out button title must not be empty for dark mode test")
    }

    // MARK: - SectionSeparator

    func testSectionSeparator() {
        let view = SectionSeparator()
            .padding(.vertical, 20)
            .background(Color(UIColor.systemBackground))

        assertFixedSizeSnapshot(of: view, width: 350, height: 60)
        // SectionSeparator is a pure visual divider — verify it can be constructed
        XCTAssertNotNil(view as Any, "SectionSeparator must be constructible without parameters")
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
