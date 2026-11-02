//
//  TPPSignOutCompletesLocallyTests.swift
//  PalaceTests
//
//  Sign Out must always remove the patron's credentials from this device:
//  when Adobe deauthorization answers, when it never answers, when the
//  business logic is released mid-sign-out, and when the server sign-out
//  fails with a 401 or no connection (PP-5449).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TPPSignOutCompletesLocallyTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic?
    private var libraryMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var bookRegistry: TPPBookRegistryMock!
    private var downloadCenter: TPPMyBooksDownloadsCenterMock!
    private var userAccount: TPPUserAccount!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        bookRegistry = TPPBookRegistryMock()
        downloadCenter = TPPMyBooksDownloadsCenterMock()

        let logic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
        businessLogic = logic
        userAccount = logic.userAccount
    }

    override func tearDown() {
        networkExecutor.reset()
        drmAuthorizer.reset()
        userAccount.removeAll()
        businessLogic = nil
        userAccount = nil
        libraryMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        networkExecutor = nil
        bookRegistry = nil
        downloadCenter = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func signIn(_ logic: TPPSignInBusinessLogic, barcode: String = "01230000000128") {
        logic.selectedAuthentication = libraryMock.barcodeAuthentication
        logic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: barcode,
            pin: "testpin",
            authToken: nil,
            expirationDate: nil,
            patron: ["name": "Test Patron"],
            cookies: nil
        )
        logic.userAccount.setLicensor([
            "vendor": "test-vendor",
            "clientToken": "test-user|test-password"
        ])
    }

    /// Polls a condition on the main actor; returns its final value.
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - Deauthorization answers

    func testSignOut_WhenDeauthorizationCompletes_RemovesCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing)
    }

    /// A deauthorization that answered must not leave a timeout armed that later
    /// wipes credentials from a sign-in the patron made afterwards.
    func testSignOut_WhenDeauthorizationCompletesThenPatronSignsIn_TimeoutKeepsNewCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.3
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)

        logic.cancelPendingSignOut()
        signIn(logic, barcode: "new-barcode")
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(userAccount.hasCredentials(), "The timeout of a finished sign-out ran cleanup again")
        XCTAssertEqual(userAccount.barcode, "new-barcode")
    }

    /// Deauthorization answering first must not let the timeout run the
    /// cleanup a second time; a second pass repeats the sign-out notification.
    func testSignOut_WhenDeauthorizationCompletesBeforeTimeout_CleansUpOnce() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs.count, 1)
    }

    /// A deauthorization answering after the timeout must not run the cleanup
    /// a second time.
    func testSignOut_WhenDeauthorizationAnswersAfterTimeout_CleansUpOnce() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        drmAuthorizer.completeDeferredDeauthorize()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs.count, 1)
    }

    // MARK: - Deauthorization never answers

    func testSignOut_WhenDeauthorizationNeverCompletes_RemovesCredentialsAfterTimeout() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed, "Sign-out waited on a deauthorization that never answered")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing, "The Signing Out spinner never ends without this callback")
        XCTAssertFalse(logic.isSignOutInProgressForTests, "Further Sign Out taps are ignored while this stays true")
    }

    /// The deauthorization answering after the timeout already signed the patron
    /// out, and after they signed in again, must not remove the new credentials.
    func testSignOut_WhenDeauthorizationAnswersAfterTimeoutAndNewSignIn_KeepsNewCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)

        logic.cancelPendingSignOut()
        signIn(logic, barcode: "new-barcode")
        drmAuthorizer.completeDeferredDeauthorize()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(userAccount.barcode, "new-barcode")
    }

    // MARK: - Business logic released mid-sign-out

    func testSignOut_WhenBusinessLogicReleasedBeforeDeauthorizationAnswers_RemovesCredentials() async throws {
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401
        weak var released: TPPSignInBusinessLogic?
        do {
            let logic = try XCTUnwrap(businessLogic)
            signIn(logic)
            await logic.performLogOut()
            released = logic
        }
        businessLogic = nil
        XCTAssertNil(released, "Precondition: the business logic must be released for this case")
        XCTAssertTrue(userAccount.hasCredentials(), "Precondition: deauthorization has not answered yet")

        drmAuthorizer.completeDeferredDeauthorize()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed, "Credentials stayed in the keychain after Sign Out")
        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs.count, 1, "Downloaded books stay on the device")
        XCTAssertEqual(bookRegistry.resetCalledLibraryIDs.count, 1, "Loans stay in the registry")
    }

    /// A patron who signed in again before the released sign-out's callback
    /// arrived keeps the new credentials.
    func testSignOut_WhenBusinessLogicReleasedAndPatronSignsInAgain_KeepsNewCredentials() async throws {
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401
        weak var released: TPPSignInBusinessLogic?
        do {
            let logic = try XCTUnwrap(businessLogic)
            signIn(logic)
            await logic.performLogOut()
            released = logic
        }
        businessLogic = nil
        XCTAssertNil(released, "Precondition: the business logic must be released for this case")

        userAccount.incrementSignInGeneration()
        drmAuthorizer.completeDeferredDeauthorize()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(userAccount.hasCredentials(), "A late callback removed credentials from a newer sign-in")
        XCTAssertTrue(downloadCenter.resetCalledLibraryIDs.isEmpty)
    }

    func testSignOut_WhenBusinessLogicReleasedAndDeauthorizationNeverAnswers_RemovesCredentials() async throws {
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401
        weak var released: TPPSignInBusinessLogic?
        do {
            let logic = try XCTUnwrap(businessLogic)
            logic.adobeDeauthorizationTimeout = 0.2
            signIn(logic)
            await logic.performLogOut()
            released = logic
        }
        businessLogic = nil
        XCTAssertNil(released, "Precondition: the business logic must be released for this case")

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
    }

    // MARK: - Server sign-out fails

    func testSignOut_WhenServerReturns401AndDeauthorizationHangs_RemovesCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        XCTAssertFalse(uiDelegate.didCallSignOutError, "A 401 on sign-out is expected and not shown")
    }

    func testSignOut_WhenOffline_RemovesCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        logic.adobeDeauthorizationTimeout = 0.2
        signIn(logic)
        networkExecutor.forceTransportError = NSError(domain: NSURLErrorDomain,
                                                      code: NSURLErrorNotConnectedToInternet)

        await logic.performLogOut()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed, "An offline sign-out left the patron signed in")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing)
    }
}
