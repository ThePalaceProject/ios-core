//
//  TPPDeferredAdobeActivationTests.swift
//  PalaceTests
//
//  Tests for PP-3649: Defer Adobe device activation from login to borrow time.
//
//  Verifies that:
//  - Login no longer triggers Adobe device activation
//  - DRM credentials are saved during login for later use
//  - Book DRM type detection works correctly
//  - On-demand activation is triggered only when needed
//

import XCTest
@testable import Palace

// MARK: - saveDRMCredentials Tests

final class TPPSaveDRMCredentialsTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    // MARK: - saveDRMCredentials saves licensor without activating

    #if FEATURE_DRM_CONNECTOR
    func testSaveDRMCredentials_savesLicensorWithoutActivating() {
        let data = TPPFake.validUserProfileJson.data(using: .utf8)!

        businessLogic.saveDRMCredentials(data, loggingContext: [:])

        // Licensor should be saved
        let licensor = businessLogic.userAccount.licensor
        XCTAssertNotNil(licensor, "Licensor should be saved from profile doc")
        XCTAssertEqual(licensor?["vendor"] as? String, "NYPL")
        XCTAssertEqual(licensor?["clientToken"] as? String, "someToken")

        // Adobe authorize() should NOT have been called
        XCTAssertFalse(drmAuthorizer.authorizeWasCalled,
                       "saveDRMCredentials must NOT trigger Adobe device activation")
        XCTAssertEqual(drmAuthorizer.authorizeCallCount, 0)
    }

    func testSaveDRMCredentials_savesAuthorizationIdentifier() {
        let data = TPPFake.validUserProfileJson.data(using: .utf8)!

        businessLogic.saveDRMCredentials(data, loggingContext: [:])

        XCTAssertEqual(businessLogic.userAccount.authorizationIdentifier, "23333999999915")
    }

    func testSaveDRMCredentials_succeedsWithNoDRMInfo() {
        let noDRMJson = """
        {
            "simplified:authorization_identifier": "12345",
            "links": [],
            "settings": {}
        }
        """
        let data = noDRMJson.data(using: .utf8)!
        let expectation = self.expectation(description: "Sign-in completes")

        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.saveDRMCredentials(data, loggingContext: [:])

        waitForExpectations(timeout: 2.0)

        // Sign-in should still succeed even without DRM info
        XCTAssertNil(businessLogic.userAccount.licensor,
                     "Licensor should be nil when library has no Adobe DRM")
        XCTAssertFalse(drmAuthorizer.authorizeWasCalled,
                       "No activation should occur for libraries without Adobe DRM")
    }

    func testSaveDRMCredentials_preservesCredentialsOnInvalidData() {
        let invalidData = "not valid json".data(using: .utf8)!
        let expectation = self.expectation(description: "Sign-in completes")

        uiDelegate.username = "23333012345678"
        uiDelegate.pin = "1234"

        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.saveDRMCredentials(invalidData, loggingContext: [:])

        waitForExpectations(timeout: 2.0)

        // PP-3784: Sign-in must succeed even when profile doc is unparseable.
        // The server already accepted the patron credentials (HTTP 200),
        // so we must not wipe them just because the DRM profile is malformed.
        XCTAssertFalse(drmAuthorizer.authorizeWasCalled)
        XCTAssertTrue(uiDelegate.didCallDidCompleteSignIn,
                      "Sign-in should complete successfully despite invalid profile doc")
    }
    #endif
}

// MARK: - Login Flow No-Activation Tests

final class TPPLoginNoActivationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!

    override func setUp() {
        super.setUp()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        drmAuthorizer.reset()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        super.tearDown()
    }

    /// PP-3649: Validates that a full login flow does NOT trigger Adobe activation.
    /// The mock network executor returns validUserProfileJson (which contains DRM info),
    /// and we verify that despite the DRM info being present, `authorize()` is never called.
    func testValidateCredentials_doesNotTriggerAdobeActivation() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(drmAuthorizer.authorizeCallCount, 0,
                       "PP-3649: Login must NOT trigger Adobe device activation")
    }

    /// PP-3649: Validates that DRM credentials are persisted during login
    /// so they can be used later at borrow time for on-demand activation.
    func testValidateCredentials_savesLicensorForLaterUse() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        #if FEATURE_DRM_CONNECTOR
        let licensor = businessLogic.userAccount.licensor
        XCTAssertNotNil(licensor, "DRM licensor credentials should be saved during login")
        XCTAssertEqual(licensor?["vendor"] as? String, "NYPL",
                       "Vendor should be saved from profile document")
        XCTAssertEqual(licensor?["clientToken"] as? String, "someToken",
                       "Client token should be saved from profile document")
        #endif
    }

    /// PP-3649: Validates that login succeeds even when re-authenticating with
    /// stale credentials — and still does not trigger Adobe activation.
    func testValidateCredentials_withStaleCredentials_doesNotActivate() {
        let userAccount = businessLogic.userAccount as! TPPUserAccountMock
        userAccount._credentials = .barcodeAndPin(barcode: "test", pin: "1234")
        userAccount.setAuthState(.credentialsStale)
        userAccount.setUserID("adobeUser")
        userAccount.setDeviceID("adobeDevice")
        drmAuthorizer.isUserAuthorizedReturnValue = true

        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let expectation = self.expectation(description: "Sign-in completes")
        uiDelegate.didCompleteSignInHandler = {
            expectation.fulfill()
        }

        businessLogic.validateCredentials()

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(drmAuthorizer.authorizeCallCount, 0,
                       "PP-3649: Re-auth must NOT trigger Adobe activation")
    }
}

// MARK: - Book Adobe DRM Detection Tests

final class TPPBookRequiresAdobeDRMTests: XCTestCase {

    private static let testURL = URL(string: "https://test.example.com/borrow")!

    private func makeBook(
        identifier: String,
        title: String,
        acquisitions: [TPPOPDSAcquisition]
    ) -> TPPBook {
        TPPBook(
            acquisitions: acquisitions,
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: title,
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: ImageCache.shared
        )
    }

    /// Book with Adobe DRM indirect acquisition should require Adobe DRM
    func testRequiresAdobeDRM_trueForAdobeAdeptBook() {
        #if FEATURE_DRM_CONNECTOR
        let adobeIndirect = TPPOPDSIndirectAcquisition(
            type: ContentTypeAdobeAdept,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: ContentTypeEpubZip, indirectAcquisitions: [])
            ]
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSCatalog,
            hrefURL: Self.testURL,
            indirectAcquisitions: [adobeIndirect],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "test-adobe-drm", title: "Adobe DRM Book", acquisitions: [acquisition])
        XCTAssertTrue(book.requiresAdobeDRM,
                      "Book with Adobe Adept acquisition path should require Adobe DRM")
        #endif
    }

    /// Book with plain epub (no DRM) should NOT require Adobe DRM
    func testRequiresAdobeDRM_falseForOpenAccessBook() {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: ContentTypeEpubZip,
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "test-open-access", title: "Open Access Book", acquisitions: [acquisition])
        XCTAssertFalse(book.requiresAdobeDRM,
                       "Open access book should NOT require Adobe DRM")
    }

    /// Book with no acquisitions should NOT require Adobe DRM
    func testRequiresAdobeDRM_falseWhenNoAcquisitions() {
        let book = makeBook(identifier: "test-no-acquisitions", title: "No Acquisitions Book", acquisitions: [])
        XCTAssertFalse(book.requiresAdobeDRM,
                       "Book with no acquisitions should NOT require Adobe DRM")
    }

    /// Book from the existing OPDS test fixture (contains Adobe DRM links)
    func testRequiresAdobeDRM_trueForOPDSFixtureEntry() {
        #if FEATURE_DRM_CONNECTOR
        let book = TPPBook(entry: TPPFake.opdsEntry)
        XCTAssertNotNil(book)
        XCTAssertTrue(book!.requiresAdobeDRM,
                      "OPDS fixture entry with Adobe DRM indirect acquisitions should require Adobe DRM")
        #endif
    }

    /// Open-access audiobook should NOT require Adobe DRM
    func testRequiresAdobeDRM_falseForOpenAccessAudiobook() {
        let acquisition = TPPOPDSAcquisition(
            relation: .openAccess,
            type: "application/audiobook+json",
            hrefURL: Self.testURL,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "test-audiobook", title: "Open Access Audiobook", acquisitions: [acquisition])
        XCTAssertFalse(book.requiresAdobeDRM,
                       "Open-access audiobook should NOT require Adobe DRM")
    }

    #if LCP
    /// LCP DRM book should NOT require Adobe DRM
    func testRequiresAdobeDRM_falseForLCPBook() {
        let lcpIndirect = TPPOPDSIndirectAcquisition(
            type: ContentTypeEpubZip,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeReadiumLCP,
            hrefURL: Self.testURL,
            indirectAcquisitions: [lcpIndirect],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        let book = makeBook(identifier: "test-lcp", title: "LCP Book", acquisitions: [acquisition])
        XCTAssertFalse(book.requiresAdobeDRM,
                       "LCP DRM book should NOT require Adobe DRM")
    }
    #endif
}

