//
//  TPPSignInBusinessLogicTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
import PalaceCatalog
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

        // Bucket A migration (swarm_81b5099e): drive the state machine to
        // `.detailsLoaded` so the sub-sites that now read `loadedAccountDetails`
        // (selectedAuthentication, makeRequest, registrationIsPossible,
        // isSamlPossible, selectPreferredAuthIfNeeded, shouldShowEULALink)
        // can see the fixture's details. State-machine-aware tests for the
        // migration live in TPPSignInBusinessLogicStateMachineTests.swift.
        if let details = libraryAccountMock.tppAccount.details {
            libraryAccountMock.tppAccount._setState(.detailsLoaded(details))
        }
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        (businessLogic.networker as? TPPRequestExecutorMock)?.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
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

    // MARK: - HelpSpot 18046 — transient server errors are not "invalid credentials"

    /// A transient server failure surfaced by TokenRequest after retries are
    /// exhausted (5xx) must show the "try again" message, NOT "Invalid
    /// Credentials" — the 18046 misreport.
    func testUserFacingSignInError_TransientServer5xx_ReturnsTryAgain_Not_InvalidCredentials() {
        let error = NSError(domain: "TokenRequest", code: 503)

        let (title, message) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.networkUnavailableErrorTitle)
        XCTAssertEqual(message, Strings.Error.networkUnavailableErrorMessage)
        XCTAssertNotEqual(title, Strings.Error.invalidCredentialsErrorTitle,
                          "A transient 5xx from /token must NOT be reported as invalid credentials (HelpSpot 18046)")
    }

    /// A genuine 401 from /token IS a credential rejection — it must still show
    /// "Invalid Credentials", proving the transient branch does not over-match.
    func testUserFacingSignInError_TokenRequest401_StillReturnsInvalidCredentials() {
        let error = NSError(domain: "TokenRequest", code: 401)

        let (title, _) = TPPSignInBusinessLogic.userFacingSignInError(for: error, problemDocument: nil)

        XCTAssertEqual(title, Strings.Error.invalidCredentialsErrorTitle,
                       "A real 401 must remain an invalid-credentials message — the transient branch covers only 5xx/429/408")
    }

    func testIsTransientServerError_classification() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(TPPSignInBusinessLogic.isTransientServerError(NSError(domain: "TokenRequest", code: code)),
                          "\(code) from TokenRequest should be transient")
        }
        for code in [200, 400, 401, 403, 404] {
            XCTAssertFalse(TPPSignInBusinessLogic.isTransientServerError(NSError(domain: "TokenRequest", code: code)),
                           "\(code) from TokenRequest should NOT be transient")
        }
        // A transient code under a different domain is not a TokenRequest error.
        XCTAssertFalse(TPPSignInBusinessLogic.isTransientServerError(NSError(domain: "TPPErrorDomain", code: 503)),
                       "Domain must be TokenRequest to count as a transient token-exchange failure")
    }

    // MARK: - BUG-002 — EULA agreement copy leaks post-auth
    //
    // The Account screen renders "By signing in, you agree to the End User License
    // Agreement." directly below the Sign-out button when the patron is already
    // signed in. The copy is contextually wrong (the user is not signing in, they
    // are signed in) and must not appear post-auth. The EULA-link footer is gated
    // by `TPPSignInBusinessLogic.shouldShowEULALink()`; these tests pin its
    // sign-in-state contract.

    func testShouldShowEULALink_WhenSignedOutAndEULAURLAvailable_ReturnsTrue() {
        // Pre-auth user on a library that exposes a terms-of-service URL.
        // (NYPL mock auth doc carries a `terms-of-service` rel which maps to .eula.)
        businessLogic.userAccount.removeAll() // no credentials, authState = .loggedOut

        XCTAssertFalse(businessLogic.isSignedIn(),
                       "Precondition: user must be signed out.")
        XCTAssertNotNil(libraryAccountMock.tppAccount.details?.getLicenseURL(.eula),
                        "Precondition: mock library must expose an EULA URL.")

        XCTAssertTrue(businessLogic.shouldShowEULALink(),
                      "EULA link must be visible to a signed-out user on a library that has one — that's the prompt-of-agreement surface.")
    }

    func testShouldShowEULALink_WhenSignedIn_ReturnsFalse() {
        // Patron has authenticated. The "By signing in, you agree..." copy is
        // contextually wrong post-auth and must not appear.
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "signed-in-barcode",
                                        pin: "signed-in-pin",
                                        authToken: nil,
                                        expirationDate: nil,
                                        patron: nil,
                                        cookies: nil)

        XCTAssertTrue(businessLogic.isSignedIn(),
                      "Precondition: user must be signed in.")
        XCTAssertNotNil(libraryAccountMock.tppAccount.details?.getLicenseURL(.eula),
                        "Precondition: EULA URL still exists; visibility must hinge on sign-in state.")

        XCTAssertFalse(businessLogic.shouldShowEULALink(),
                       "BUG-002: EULA agreement copy must be hidden post-auth — the user has already agreed by virtue of being signed in.")
    }

    func testShouldShowEULALink_WhenCredentialsStale_ReturnsTrue() {
        // Stale credentials = the user must re-authenticate via the sign-in form,
        // so the agreement-copy footer is again the correct affordance.
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.updateUserAccount(forDRMAuthorization: true,
                                        withBarcode: "stale-barcode",
                                        pin: "stale-pin",
                                        authToken: nil,
                                        expirationDate: nil,
                                        patron: nil,
                                        cookies: nil)
        businessLogic.userAccount.markCredentialsStale()

        XCTAssertFalse(businessLogic.isSignedIn(),
                       "Precondition: stale credentials behave as signed-out for gating UI.")
        XCTAssertTrue(businessLogic.shouldShowEULALink(),
                      "EULA link must reappear when the sign-in form is shown for re-auth.")
    }

    // MARK: - boundedCompletion: auth-doc GET timeout seam (HelpSpot #18414)
    //
    // `ensureAuthenticationDocumentIsLoaded` gates borrow. When the auth-doc
    // fetch drops its completion, the un-bounded call hangs borrow forever (its
    // own 30s timeout is never even reached). `boundedCompletion` is the
    // extracted, network-free seam that guarantees a completion fires — either
    // the real value or `timeoutValue` — exactly once. These tests drive the
    // wedge (operation never calls back), the happy path, and the exactly-once
    // race directly, since the full method's dependency on
    // AppContainer.production().networkExecutor can't be made to hang in a unit
    // test.

    func testBoundedCompletion_operationNeverCompletes_firesTimeoutValueAfterTimeout() {
        // The wedge: the operation NEVER calls its completion (dropped auth-doc
        // fetch). boundedCompletion must still fire completion(timeoutValue).
        let done = expectation(description: "completion fires despite a hung operation")
        var received: Bool?
        var onTimeoutFired = false
        let start = Date()

        TPPSignInBusinessLogic.boundedCompletion(
            timeout: 0.3,
            timeoutValue: false,
            onTimeout: { onTimeoutFired = true },
            operation: { _ in /* never calls the completion — wedged */ },
            completion: { value in received = value; done.fulfill() }
        )

        wait(for: [done], timeout: 2.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(received, false, "a hung operation must surface the timeoutValue (false) so borrow retries")
        XCTAssertTrue(onTimeoutFired, "onTimeout hook must fire on the timeout path")
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "must actually wait ~the timeout before giving up")
        XCTAssertLessThan(elapsed, 1.5, "must not exceed the bound by a wide margin")
    }

    func testBoundedCompletion_operationCompletesFast_firesRealValue_andNeverDoubleFires() {
        // Happy path: the operation calls back quickly with the real value. The
        // timeout must NOT steal the result, and must NOT double-fire completion
        // after the timeout deadline passes.
        let done = expectation(description: "completion fires with the real value")
        var receivedValues: [Bool] = []
        var onTimeoutFired = false
        let lock = NSLock()

        TPPSignInBusinessLogic.boundedCompletion(
            timeout: 0.3,
            timeoutValue: false,
            onTimeout: { onTimeoutFired = true },
            operation: { op in
                DispatchQueue.global().async { op(true) } // real success, fast
            },
            completion: { value in
                lock.lock(); receivedValues.append(value); lock.unlock()
                done.fulfill()
            }
        )

        wait(for: [done], timeout: 1.0)

        // Wait PAST the timeout deadline to prove the cancelled timer can't
        // double-fire the completion.
        let settle = expectation(description: "settle past the timeout deadline")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: 2.0)

        lock.lock(); let values = receivedValues; lock.unlock()
        XCTAssertEqual(values, [true],
                       "completion must fire exactly once with the real value; got \(values)")
        XCTAssertFalse(onTimeoutFired,
                       "onTimeout must NOT fire when the operation completed before the deadline")
    }

    func testBoundedCompletion_zeroTimeout_stillFiresExactlyOnce() {
        // Edge: a zero timeout must not crash (max(0,timeout)) and must still
        // deliver exactly one completion — either the racing operation's value
        // or the timeoutValue, never both.
        let done = expectation(description: "completion fires exactly once at zero timeout")
        done.assertForOverFulfill = true
        var count = 0
        let lock = NSLock()

        TPPSignInBusinessLogic.boundedCompletion(
            timeout: 0,
            timeoutValue: false,
            operation: { op in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { op(true) }
            },
            completion: { _ in
                lock.lock(); count += 1; lock.unlock()
                done.fulfill()
            }
        )

        wait(for: [done], timeout: 1.0)
        // Let any (incorrectly un-guarded) second fire land before asserting.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
        lock.lock(); let final = count; lock.unlock()
        XCTAssertEqual(final, 1, "exactly-once must hold even when both racers are ready near-simultaneously")
    }
}
