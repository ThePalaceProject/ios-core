//
//  TPPSignInBusinessLogicTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

class TPPSignInBusinessLogicTests: XCTestCase {
    var businessLogic: TPPSignInBusinessLogic!
    var libraryAccountMock: TPPLibraryAccountMock!
    var drmAuthorizer: TPPDRMAuthorizingMock!
    var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer)
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        (businessLogic.networker as? TPPRequestExecutorMock)?.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
    }

    func testUpdateUserAccountWithNoSelectedAuthentication() throws {
        // preconditions
        let user = businessLogic.userAccount
        XCTAssertNotEqual(user.barcode, "newBarcode")
        XCTAssertNotEqual(user.PIN, "newPIN")

        // test
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "newBarcode",
                                        pin: "newPIN",
                                        authToken: nil,
                                        expirationDate: nil,
                                        patron: nil,
                                        cookies: nil)

        // verification
        XCTAssertEqual(user.barcode, "newBarcode")
        XCTAssertEqual(user.PIN, "newPIN")
    }

    func testUpdateUserAccountWithBarcodeAuthentication() throws {
        // preconditions
        let user = businessLogic.userAccount
        XCTAssertNotEqual(user.barcode, "newBarcode")
        XCTAssertNotEqual(user.PIN, "newPIN")
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        // test
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "newBarcode",
                                        pin: "newPIN",
                                        authToken: nil,
                                        expirationDate: nil,
                                        patron: nil,
                                        cookies: nil)

        // verification
        XCTAssertEqual(user.barcode, "newBarcode")
        XCTAssertEqual(user.PIN, "newPIN")
    }

    func testUpdateUserAccountWithCleverAuthentication() throws {
        // preconditions
        let user = businessLogic.userAccount
        XCTAssertNil(user.authToken, "user.authToken precondition should be nil")
        XCTAssertNil(user.patron, "user.patron precondition should be nil")
        XCTAssertNil(user.cookies, "user.cookies precondition should be nil")
        businessLogic.selectedAuthentication = libraryAccountMock.cleverAuthentication
        let patron = ["name": "ciccio"]

        // test
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: nil,
                                        pin: nil,
                                        authToken: "some-great-token",
                                        expirationDate: nil,
                                        patron: patron,
                                        cookies: nil)

        // verification
        XCTAssertEqual(user.authToken, "some-great-token")
        XCTAssertEqual(user.patron!["name"] as! String, "ciccio")
    }

    func testUpdateUserAccountWithSAMLAuthentication() throws {
        // preconditions
        let user = businessLogic.userAccount
        XCTAssertNil(user.authToken)
        XCTAssertNil(user.patron)
        XCTAssertNil(user.cookies)
        XCTAssertTrue(businessLogic.isSamlPossible())
        businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
        let patron = ["name": "Ciccio"]
        let cookies = [HTTPCookie(properties: [
            .domain: "www.example.com",
            .path: "test",
            .name: "biscottino",
            .value: "chocolate"
        ])!]

        // test
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: nil,
                                        pin: nil,
                                        authToken: "some-great-token",
                                        expirationDate: nil,
                                        patron: patron,
                                        cookies: cookies)

        // verification
        XCTAssertEqual(user.authToken, "some-great-token")
        XCTAssertEqual(user.patron!["name"] as! String, "Ciccio")
        XCTAssertEqual(user.cookies, cookies)
    }

    func testMakeSignInRequest() throws {
        // test sign-in request for barcode auth
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        let barcodeReq = businessLogic.makeRequest(for: .signIn, context: "barcode request test")
        XCTAssertNotNil(barcodeReq)
        let barcodeHeaderValue = barcodeReq?.value(forHTTPHeaderField: "Authorization")
        XCTAssertFalse(barcodeHeaderValue?.starts(with: "Bearer") ?? false)

        // prerequisite for both OAuth and SAML
        businessLogic.dispatch(.bearerTokenReceived(token: "tekken", expiration: nil))

        // test sign-in request for oauth auth
        businessLogic.selectedAuthentication = libraryAccountMock.oauthAuthentication
        let oauthReq = businessLogic.makeRequest(for: .signIn, context: "oauth request test")
        XCTAssertNotNil(oauthReq)
        let oauthHeaderValue = oauthReq?.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(oauthHeaderValue?.starts(with: "Bearer") ?? false)

        // test sign-in request for saml auth
        businessLogic.selectedAuthentication = libraryAccountMock.samlAuthentication
        let samlReq = businessLogic.makeRequest(for: .signIn, context: "saml request test")
        XCTAssertNotNil(samlReq)
        let samlHeaderValue = samlReq?.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(samlHeaderValue?.starts(with: "Bearer") ?? false)
    }

    func testLogInFlow() throws {
        // preconditions
        let user = businessLogic.userAccount
        XCTAssertNil(user.deviceID, "user.deviceID precondition should be nil")
        XCTAssertNil(user.userID, "user.userID precondition should be nil")
        XCTAssertNil(user.username, "user.username precondition should be nil")
        XCTAssertNil(user.barcode, "user.barcode precondition should be nil")
        XCTAssertNil(user.pin, "user.pin precondition should be nil")

        // Test that logIn() can be called and sets isValidatingCredentials
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.logIn()
        XCTAssertTrue(businessLogic.isValidatingCredentials)

        // Verify preconditions are still valid
        XCTAssertNotNil(user)
        XCTAssertNotNil(drmAuthorizer)
    }

    // MARK: - Network-vs-credentials error classification (PP-4117)
    //
    // Network loss during sign-in used to render as "Invalid Credentials"
    // because the fallback path ran unconditionally when no problem document
    // was attached. These tests pin the precedence:
    //   1. problem document > 2. network connectivity > 3. invalid credentials.

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    func testUserFacingSignInError_NoInternet_ReturnsNetworkMessage() {
        let error = urlError(NSURLErrorNotConnectedToInternet)

        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.networkUnavailableErrorTitle)
        XCTAssertEqual(message, Strings.Error.networkUnavailableErrorMessage)
        XCTAssertNotEqual(title, Strings.Error.invalidCredentialsErrorTitle,
                          "Connectivity error must not surface as invalid credentials.")
    }

    func testUserFacingSignInError_Timeout_ReturnsNetworkMessage() {
        let error = urlError(NSURLErrorTimedOut)

        let (title, _) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.networkUnavailableErrorTitle)
    }

    func testUserFacingSignInError_ConnectionLost_ReturnsNetworkMessage() {
        let error = urlError(NSURLErrorNetworkConnectionLost)

        let (title, _) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.networkUnavailableErrorTitle)
    }

    func testUserFacingSignInError_NonURLErrorDomain_ReturnsInvalidCredentials() {
        // Server returned 401 with no problem doc — not URLErrorDomain, so
        // the fallback (invalid credentials) is the correct message here.
        let error = NSError(domain: "TPPErrorDomain", code: 401)

        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.invalidCredentialsErrorTitle)
        XCTAssertEqual(message, Strings.Error.invalidCredentialsErrorMessage)
    }

    func testUserFacingSignInError_ProblemDocument_TakesPrecedenceOverNetworkError() throws {
        // If the server did respond with a problem document, its message wins
        // even if the underlying NSError code happens to match a network code.
        let error = urlError(NSURLErrorTimedOut)
        let json = #"{"type":"about:blank","title":"Account Locked","detail":"Too many attempts."}"#
        let problemDoc = try TPPProblemDocument.fromData(Data(json.utf8))

        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: problemDoc)

        XCTAssertEqual(title, "Account Locked")
        XCTAssertEqual(message, "Too many attempts.")
    }

    func testIsNetworkConnectivityError_OnlyRecognizesURLErrorDomain() {
        XCTAssertTrue(TPPSignInBusinessLogic.isNetworkConnectivityError(urlError(NSURLErrorNotConnectedToInternet)))
        XCTAssertTrue(TPPSignInBusinessLogic.isNetworkConnectivityError(urlError(NSURLErrorCannotFindHost)))
        XCTAssertTrue(TPPSignInBusinessLogic.isNetworkConnectivityError(urlError(NSURLErrorSecureConnectionFailed)))

        XCTAssertFalse(TPPSignInBusinessLogic.isNetworkConnectivityError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)),
            "HTTP auth failures surfaced as URLErrors must NOT be classified as connectivity errors.")
        XCTAssertFalse(TPPSignInBusinessLogic.isNetworkConnectivityError(
            NSError(domain: "TPPErrorDomain", code: NSURLErrorNotConnectedToInternet)),
            "Same code under a different domain is not a URLSession connectivity error.")
    }
}
