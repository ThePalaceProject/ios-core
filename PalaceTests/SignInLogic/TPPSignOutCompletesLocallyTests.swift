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

    /// Holds the sign-out timeout instead of arming a timer, so a test decides
    /// when it fires.
    private final class CapturedTimeout: @unchecked Sendable {
        var delay: TimeInterval?
        var work: (@Sendable () -> Void)?

        func fire() { work?() }
    }

    private func captureTimeout(_ logic: TPPSignInBusinessLogic) -> CapturedTimeout {
        let captured = CapturedTimeout()
        logic.deauthorizationTimeoutScheduler = { delay, work in
            captured.delay = delay
            captured.work = work
        }
        return captured
    }

    /// Runs everything already queued on the main actor, including the cleanup
    /// a latch fire schedules, so "nothing happened" is read after it would have.
    private func drainMainQueue() async {
        for _ in 0..<3 {
            let drained = expectation(description: "main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 5) // STARVE-001-OK: waits on one main-queue hop, not on async work
        }
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

    /// The bound on the wait is 30 seconds.
    func testSignOut_ArmsTimeoutOfThirtySeconds() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()

        XCTAssertEqual(timeout.delay, 30)
    }

    /// A deauthorization that answered must not leave a timeout armed that later
    /// wipes credentials from a sign-in the patron made afterwards.
    func testSignOut_WhenDeauthorizationCompletesThenPatronSignsIn_TimeoutKeepsNewCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)

        logic.cancelPendingSignOut()
        signIn(logic, barcode: "new-barcode")
        XCTAssertNotNil(timeout.work, "Precondition: sign-out armed a timeout")
        timeout.fire()
        await drainMainQueue()

        XCTAssertTrue(userAccount.hasCredentials(), "The timeout of a finished sign-out ran cleanup again")
        XCTAssertEqual(userAccount.barcode, "new-barcode")
    }

    /// Deauthorization answering first must not let the timeout run the
    /// cleanup a second time; a second pass repeats the sign-out notification.
    func testSignOut_WhenDeauthorizationCompletesBeforeTimeout_CleansUpOnce() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        XCTAssertNotNil(timeout.work, "Precondition: sign-out armed a timeout")
        timeout.fire()
        await drainMainQueue()

        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs.count, 1)
    }

    // MARK: - Deauthorization never answers

    /// Uses the real timer, so the production scheduling path is exercised.
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

    /// A deauthorization answering after the timeout must not run the cleanup
    /// a second time.
    func testSignOut_WhenDeauthorizationAnswersAfterTimeout_CleansUpOnce() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        timeout.fire()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)

        XCTAssertNotNil(drmAuthorizer.deferredDeauthCompletion, "Precondition: the deauthorization callback is pending")
        drmAuthorizer.completeDeferredDeauthorize()
        XCTAssertNil(drmAuthorizer.deferredDeauthCompletion, "The late callback did not run")
        await drainMainQueue()

        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs.count, 1)
    }

    /// The deauthorization answering after the timeout already signed the patron
    /// out, and after they signed in again, must not remove the new credentials.
    func testSignOut_WhenDeauthorizationAnswersAfterTimeoutAndNewSignIn_KeepsNewCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        timeout.fire()
        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)

        logic.cancelPendingSignOut()
        signIn(logic, barcode: "new-barcode")
        XCTAssertNotNil(drmAuthorizer.deferredDeauthCompletion, "Precondition: the deauthorization callback is pending")
        drmAuthorizer.completeDeferredDeauthorize()
        XCTAssertNil(drmAuthorizer.deferredDeauthCompletion, "The late callback did not run")
        await drainMainQueue()

        XCTAssertEqual(userAccount.barcode, "new-barcode")
    }

    // MARK: - Business logic released mid-sign-out

    func testSignOut_WhenBusinessLogicReleasedBeforeDeauthorizationAnswers_RemovesCredentials() async throws {
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401
        libraryMock.tppAccount.hasUpdatedToken = true
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
        let libraryID = libraryMock.tppAccountUUID
        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs, [libraryID], "Downloaded books stay on the device")
        XCTAssertEqual(bookRegistry.resetCalledLibraryIDs, [libraryID], "Loans stay in the registry")
        XCTAssertFalse(libraryMock.tppAccount.hasUpdatedToken, "The push token is not re-registered on the next sign-in")
    }

    func testSignOut_WhenBusinessLogicReleasedAndDeauthorizationNeverAnswers_RemovesCredentials() async throws {
        drmAuthorizer.shouldDeferDeauthorize = true
        networkExecutor.forceFailureStatusCode = 401
        weak var released: TPPSignInBusinessLogic?
        var timeout: CapturedTimeout?
        do {
            let logic = try XCTUnwrap(businessLogic)
            timeout = captureTimeout(logic)
            signIn(logic)
            await logic.performLogOut()
            released = logic
        }
        businessLogic = nil
        XCTAssertNil(released, "Precondition: the business logic must be released for this case")

        XCTAssertNotNil(timeout?.work, "Precondition: sign-out armed a timeout")
        timeout?.fire()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        XCTAssertEqual(downloadCenter.resetCalledLibraryIDs, [libraryMock.tppAccountUUID])
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
        XCTAssertNotNil(drmAuthorizer.deferredDeauthCompletion, "Precondition: the deauthorization callback is pending")
        drmAuthorizer.completeDeferredDeauthorize()
        XCTAssertNil(drmAuthorizer.deferredDeauthCompletion, "The late callback did not run")
        await drainMainQueue()

        XCTAssertTrue(userAccount.hasCredentials(), "A late callback removed credentials from a newer sign-in")
        XCTAssertTrue(downloadCenter.resetCalledLibraryIDs.isEmpty)
    }

    // MARK: - Server sign-out fails

    func testSignOut_WhenServerReturns401AndDeauthorizationHangs_RemovesCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        let timeout = captureTimeout(logic)
        drmAuthorizer.shouldDeferDeauthorize = true
        signIn(logic)
        networkExecutor.forceFailureStatusCode = 401

        await logic.performLogOut()
        timeout.fire()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed)
        XCTAssertFalse(uiDelegate.didCallSignOutError, "A 401 on sign-out is expected and not shown")
    }

    func testSignOut_WhenOffline_RemovesCredentials() async throws {
        let logic = try XCTUnwrap(businessLogic)
        signIn(logic)
        networkExecutor.forceTransportError = NSError(domain: NSURLErrorDomain,
                                                      code: NSURLErrorNotConnectedToInternet)

        await logic.performLogOut()

        let removed = await eventually { !self.userAccount.hasCredentials() }
        XCTAssertTrue(removed, "An offline sign-out left the patron signed in")
        XCTAssertTrue(uiDelegate.didCallDidFinishDeauthorizing)
    }
}
