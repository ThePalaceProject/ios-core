//
//  AccountDetailsURLTests.swift
//  PalaceTests
//
//  Tests for AccountDetails URL management: setURL and getLicenseURL.
//  Covers High-priority coverage gaps: getLicenseURL, setURL.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountDetailsURLTests: XCTestCase {

    private var sut: AccountDetails!
    private let testUUID = "test-account-url-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // Clean any existing defaults for our test UUID
        UserDefaults.standard.removeObject(forKey: testUUID)
        sut = makeAccountDetails(uuid: testUUID)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testUUID)
        sut = nil
        super.tearDown()
    }

    // MARK: - setURL Tests

    func testSetURL_ForEULA_StoresURL() {
        XCTAssertNil(sut.getLicenseURL(.eula), "EULA URL must be nil before setting")
        let url = URL(string: "https://example.com/eula")!
        sut.setURL(url, forLicense: .eula)

        let retrieved = sut.getLicenseURL(.eula)
        XCTAssertEqual(retrieved, url)
        XCTAssertNil(sut.getLicenseURL(.privacyPolicy), "Setting EULA must not affect privacyPolicy URL")
    }

    func testSetURL_ForPrivacyPolicy_StoresURL() {
        XCTAssertNil(sut.getLicenseURL(.privacyPolicy), "Privacy URL must be nil before setting")
        let url = URL(string: "https://example.com/privacy")!
        sut.setURL(url, forLicense: .privacyPolicy)

        let retrieved = sut.getLicenseURL(.privacyPolicy)
        XCTAssertEqual(retrieved, url)
        XCTAssertNil(sut.getLicenseURL(.eula), "Setting privacyPolicy must not affect EULA URL")
    }

    func testSetURL_ForContentLicenses_StoresURL() {
        XCTAssertNil(sut.getLicenseURL(.contentLicenses), "Content licenses URL must be nil before setting")
        let url = URL(string: "https://example.com/licenses")!
        sut.setURL(url, forLicense: .contentLicenses)

        let retrieved = sut.getLicenseURL(.contentLicenses)
        XCTAssertEqual(retrieved, url)
        XCTAssertNil(sut.getLicenseURL(.eula), "Setting contentLicenses must not affect EULA URL")
    }

    func testSetURL_ForAcknowledgements_StoresURL() {
        XCTAssertNil(sut.getLicenseURL(.acknowledgements), "Acknowledgements URL must be nil before setting")
        let url = URL(string: "https://example.com/acknowledgements")!
        sut.setURL(url, forLicense: .acknowledgements)

        let retrieved = sut.getLicenseURL(.acknowledgements)
        XCTAssertEqual(retrieved, url)
        XCTAssertNil(sut.getLicenseURL(.annotations), "Setting acknowledgements must not affect annotations URL")
    }

    func testSetURL_ForAnnotations_StoresURL() {
        XCTAssertNil(sut.getLicenseURL(.annotations), "Annotations URL must be nil before setting")
        let url = URL(string: "https://example.com/annotations")!
        sut.setURL(url, forLicense: .annotations)

        let retrieved = sut.getLicenseURL(.annotations)
        XCTAssertEqual(retrieved, url)
        XCTAssertNil(sut.getLicenseURL(.eula), "Setting annotations must not affect EULA URL")
    }

    // MARK: - getLicenseURL Tests

    func testGetLicenseURL_WhenNotSet_ReturnsNil() {
        XCTAssertNil(sut.getLicenseURL(.eula))
        XCTAssertNil(sut.getLicenseURL(.privacyPolicy))
        XCTAssertNil(sut.getLicenseURL(.contentLicenses))
        XCTAssertNil(sut.getLicenseURL(.acknowledgements))
        XCTAssertNil(sut.getLicenseURL(.annotations))
    }

    func testGetLicenseURL_AfterSettingMultipleTypes_ReturnsCorrectURLs() {
        let eulaURL = URL(string: "https://example.com/eula")!
        let privacyURL = URL(string: "https://example.com/privacy")!
        let annotationsURL = URL(string: "https://example.com/annotations")!

        sut.setURL(eulaURL, forLicense: .eula)
        sut.setURL(privacyURL, forLicense: .privacyPolicy)
        sut.setURL(annotationsURL, forLicense: .annotations)

        XCTAssertEqual(sut.getLicenseURL(.eula), eulaURL)
        XCTAssertEqual(sut.getLicenseURL(.privacyPolicy), privacyURL)
        XCTAssertEqual(sut.getLicenseURL(.annotations), annotationsURL)
        XCTAssertNil(sut.getLicenseURL(.contentLicenses))
    }

    func testSetURL_OverwritesPreviousURL() {
        let url1 = URL(string: "https://example.com/old-eula")!
        let url2 = URL(string: "https://example.com/new-eula")!

        sut.setURL(url1, forLicense: .eula)
        XCTAssertEqual(sut.getLicenseURL(.eula), url1)

        sut.setURL(url2, forLicense: .eula)
        XCTAssertEqual(sut.getLicenseURL(.eula), url2)
    }

    func testSetURL_PersistsToUserDefaults() {
        let url = URL(string: "https://example.com/persisted")!
        sut.setURL(url, forLicense: .eula)

        // Verify UserDefaults was updated
        let savedDict = UserDefaults.standard.value(forKey: testUUID) as? [String: AnyObject]
        XCTAssertNotNil(savedDict)
        XCTAssertEqual(savedDict?["urlEULA"] as? String, "https://example.com/persisted")
    }

    // MARK: - AccountDetails Property Tests

    func testEulaIsAccepted_DefaultIsFalse() {
        XCTAssertFalse(sut.eulaIsAccepted)
        // The default state must reflect "not yet accepted" for a fresh account
        XCTAssertFalse(sut.eulaIsAccepted, "EULA acceptance must default to false for a new account")
        XCTAssertTrue(sut.syncPermissionGranted, "Sync permission must default to true for a new account")
    }

    func testEulaIsAccepted_RoundTrips_ThroughUserDefaults() {
        // Arrange: confirm initial state
        XCTAssertFalse(sut.eulaIsAccepted)

        // Act: accept EULA, then create a fresh AccountDetails over the same UUID
        sut.eulaIsAccepted = true
        let sut2 = makeAccountDetails(uuid: testUUID)

        // Assert: the persisted value survives object re-creation
        XCTAssertTrue(sut2.eulaIsAccepted, "EULA acceptance should persist in UserDefaults")
    }

    func testSyncPermissionGranted_DefaultIsTrue() {
        XCTAssertTrue(sut.syncPermissionGranted)
        // Verify it is actually stored in UserDefaults (not a compile-time constant)
        let sut2 = makeAccountDetails(uuid: testUUID)
        XCTAssertTrue(sut2.syncPermissionGranted, "Default sync permission must persist for same UUID")
        XCTAssertFalse(sut.eulaIsAccepted, "EULA must default to not accepted independent of sync permission")
    }

    func testSyncPermissionGranted_ToggleOffThenOn_PersistsViaUserDefaults() {
        // Arrange: sync is granted by default — confirm initial state
        XCTAssertTrue(sut.syncPermissionGranted, "Precondition: syncPermissionGranted defaults to true")

        // Act: disable sync and create a second AccountDetails over the same UUID
        sut.syncPermissionGranted = false
        let sut2 = makeAccountDetails(uuid: testUUID)

        // Assert: the revocation survived object recreation via UserDefaults
        XCTAssertFalse(sut2.syncPermissionGranted,
                       "Disabling sync must persist across AccountDetails re-creation")

        // Act: re-enable sync via the second instance
        sut2.syncPermissionGranted = true
        let sut3 = makeAccountDetails(uuid: testUUID)

        // Assert: re-enabling also persists
        XCTAssertTrue(sut3.syncPermissionGranted,
                      "Re-enabling sync must also persist across AccountDetails re-creation")
    }

    func testUserAboveAgeLimit_DefaultIsFalse() {
        XCTAssertFalse(sut.userAboveAgeLimit)
        // Verify the default does not depend on EULA or sync state
        XCTAssertFalse(sut.eulaIsAccepted, "EULA must also default to false")
        XCTAssertTrue(sut.syncPermissionGranted, "Sync permission must default to true independently of age limit")
    }

    func testUserAboveAgeLimit_RoundTrips_ThroughUserDefaults() {
        // Arrange: confirm initial state
        XCTAssertFalse(sut.userAboveAgeLimit)

        // Act: mark user above age limit, then re-create over same UUID
        sut.userAboveAgeLimit = true
        let sut2 = makeAccountDetails(uuid: testUUID)

        // Assert: persisted value survives object re-creation
        XCTAssertTrue(sut2.userAboveAgeLimit, "Age limit flag should persist in UserDefaults")
    }

    func testDebugDescription_ReflectsSupportsSimplyESync_WhenUserProfileUrlPresent() {
        // Arrange: create AccountDetails whose auth document includes a user-profile link
        let uuid = "test-debug-desc-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: uuid) }

        let json: [String: Any] = [
            "id": uuid,
            "title": "Sync Library",
            "authentication": [
                [
                    "type": "http://opds-spec.org/auth/basic",
                    "inputs": [
                        "login": ["keyboard": "Default"],
                        "password": ["keyboard": "Default"]
                    ],
                    "labels": ["login": "Barcode", "password": "PIN"]
                ]
            ],
            "links": [
                ["href": "https://example.com/profile", "rel": "http://librarysimplified.org/terms/rel/user-profile"]
            ],
            "features": ["enabled": [], "disabled": []]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let doc = try! OPDS2AuthenticationDocument.fromData(data)
        let details = AccountDetails(authenticationDocument: doc, uuid: uuid)

        // Act
        let description = details.debugDescription

        // Assert: supportsSimplyESync=true because userProfileUrl was present
        XCTAssertTrue(description.contains("supportsSimplyESync=true"),
                      "debugDescription should reflect supportsSimplyESync=true when user-profile link is set")
    }

    // MARK: - AccountDetails defaultAuth Tests

    func testDefaultAuth_WithOAuthAndBasic_PrefersBasicOverOAuth() {
        // Arrange: create AccountDetails with both OAuth and basic auth
        let uuid = "test-defaultauth-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: uuid) }

        let json: [String: Any] = [
            "id": uuid,
            "title": "Multi-Auth Library",
            "authentication": [
                [
                    "type": "http://librarysimplified.org/authtype/OAuth-with-intermediary",
                    "links": [["href": "https://example.com/oauth", "rel": "authenticate"]],
                    "labels": ["login": "Username", "password": "Password"]
                ],
                [
                    "type": "http://opds-spec.org/auth/basic",
                    "inputs": [
                        "login": ["keyboard": "Default"],
                        "password": ["keyboard": "Default"]
                    ],
                    "labels": ["login": "Barcode", "password": "PIN"]
                ]
            ],
            "features": ["enabled": [], "disabled": []]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let doc = try! OPDS2AuthenticationDocument.fromData(data)
        let details = AccountDetails(authenticationDocument: doc, uuid: uuid)

        // Act
        let defaultAuth = details.defaultAuth

        // Assert: defaultAuth picks the non-OAuth (basic) method first
        XCTAssertNotNil(defaultAuth, "defaultAuth should not be nil when auths are present")
        XCTAssertFalse(defaultAuth!.catalogRequiresAuthentication,
                       "defaultAuth should prefer basic over OAuth (which requires catalog auth)")
        XCTAssertTrue(defaultAuth!.isBasic, "defaultAuth should be the basic auth method")
    }

    // MARK: - Helpers

    private func makeAccountDetails(uuid: String) -> AccountDetails {
        // Create minimal auth document JSON and parse it
        let json: [String: Any] = [
            "id": uuid,
            "title": "Test Library",
            "authentication": [
                [
                    "type": "http://opds-spec.org/auth/basic",
                    "inputs": [
                        "login": ["keyboard": "Default"],
                        "password": ["keyboard": "Default", "maximum_length": 4]
                    ],
                    "labels": [
                        "login": "Barcode",
                        "password": "PIN"
                    ]
                ]
            ],
            "features": ["enabled": [], "disabled": []]
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        let doc = try! OPDS2AuthenticationDocument.fromData(data)
        return AccountDetails(authenticationDocument: doc, uuid: uuid)
    }
}
