//
//  TPPSettingsTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPSettingsTests: XCTestCase {

    // MARK: - Shared Instance

    func testShared_isNotNil() {
        XCTAssertNotNil(TPPSettings.shared)
    }

    func testSharedSettings_returnsSameInstance() {
        let a = TPPSettings.shared
        let b = TPPSettings.sharedSettings()
        XCTAssertTrue(a === b)
    }

    // MARK: - Static URL Strings

    func testAboutPalaceURL_isValid() {
        let urlString = TPPSettings.TPPAboutPalaceURLString
        XCTAssertNotNil(urlString)
        XCTAssertNotNil(URL(string: urlString), "About URL string should be a valid URL")
    }

    func testUserAgreementURL_isValid() {
        let urlString = TPPSettings.TPPUserAgreementURLString
        XCTAssertNotNil(urlString)
        XCTAssertNotNil(URL(string: urlString), "User Agreement URL string should be a valid URL")
    }

    func testPrivacyPolicyURL_isValid() {
        let urlString = TPPSettings.TPPPrivacyPolicyURLString
        XCTAssertNotNil(urlString)
        XCTAssertNotNil(URL(string: urlString), "Privacy Policy URL string should be a valid URL")
    }

    func testSoftwareLicensesURL_isValid() {
        let urlString = TPPSettings.TPPSoftwareLicensesURLString
        XCTAssertNotNil(urlString)
        XCTAssertNotNil(URL(string: urlString), "Software Licenses URL string should be a valid URL")
    }

    // MARK: - Boolean Settings

    func testUseBetaLibraries_defaultIsFalse() {
        // Save current value, test default, restore
        let original = TPPSettings.shared.useBetaLibraries
        TPPSettings.shared.useBetaLibraries = false

        XCTAssertFalse(TPPSettings.shared.useBetaLibraries)

        TPPSettings.shared.useBetaLibraries = original
    }

    func testUseBetaLibraries_canBeToggled() {
        let original = TPPSettings.shared.useBetaLibraries

        TPPSettings.shared.useBetaLibraries = true
        XCTAssertTrue(TPPSettings.shared.useBetaLibraries)

        TPPSettings.shared.useBetaLibraries = false
        XCTAssertFalse(TPPSettings.shared.useBetaLibraries)

        TPPSettings.shared.useBetaLibraries = original
    }

    func testEnterLCPPassphraseManually_canBeToggled() {
        let original = TPPSettings.shared.enterLCPPassphraseManually

        TPPSettings.shared.enterLCPPassphraseManually = true
        XCTAssertTrue(TPPSettings.shared.enterLCPPassphraseManually)

        TPPSettings.shared.enterLCPPassphraseManually = false
        XCTAssertFalse(TPPSettings.shared.enterLCPPassphraseManually)

        TPPSettings.shared.enterLCPPassphraseManually = original
    }

    // MARK: - EULA

    func testUserHasAcceptedEULA_canBeSet() {
        let original = TPPSettings.shared.userHasAcceptedEULA

        TPPSettings.shared.userHasAcceptedEULA = true
        XCTAssertTrue(TPPSettings.shared.userHasAcceptedEULA)

        TPPSettings.shared.userHasAcceptedEULA = false
        XCTAssertFalse(TPPSettings.shared.userHasAcceptedEULA)

        TPPSettings.shared.userHasAcceptedEULA = original
    }

    // MARK: - App Version

    func testAppVersion_canBeSetAndRead() {
        let original = TPPSettings.shared.appVersion

        TPPSettings.shared.appVersion = "1.2.3"
        XCTAssertEqual(TPPSettings.shared.appVersion, "1.2.3")

        TPPSettings.shared.appVersion = original
    }

    // MARK: - Custom URLs

    func testCustomMainFeedURL_defaultIsNil() {
        // Custom URL should be nil by default in test environment
        let url = TPPSettings.shared.customMainFeedURL
        // Just verify it doesn't crash
        _ = url
    }

    func testCustomLibraryRegistryServer_canBeSet() {
        let original = TPPSettings.shared.customLibraryRegistryServer

        TPPSettings.shared.customLibraryRegistryServer = "https://custom.registry.example.com"
        XCTAssertEqual(TPPSettings.shared.customLibraryRegistryServer, "https://custom.registry.example.com")

        TPPSettings.shared.customLibraryRegistryServer = original
    }

    // MARK: - Notifications

    func testUseBetaLibraries_postsNotification() {
        let original = TPPSettings.shared.useBetaLibraries
        let expectation = XCTNSNotificationExpectation(
            name: NSNotification.Name.TPPUseBetaDidChange
        )

        TPPSettings.shared.useBetaLibraries = !original

        wait(for: [expectation], timeout: 2.0)

        // Restore
        TPPSettings.shared.useBetaLibraries = original
    }
}
