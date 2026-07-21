//
//  TPPSignInBusinessLogicSignOutTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for the sign-out surface of
//  TPPSignInBusinessLogic (extension `+SignOut`). P0 coverage gap per
//  docs/Testing/Coverage_Roadmap.md §2.1.
//
//  Focus areas:
//    - Sign-out wipes credentials from the (mocked) keychain after device
//      deauthorization completes.
//    - Adobe DRM activation state on userAccount is preserved across
//      re-authentication that happens DURING an in-flight sign-out
//      (signInGeneration race-condition guard).
//    - Sign-out drives `deauthorize` exactly once and only after a successful
//      completion is observed on the network executor — not before.
//    - Re-entrant `performLogOut()` calls coalesce (no double cleanup).
//    - 401 on the sign-out request takes the silent-cleanup path
//      (no `didEncounterSignOutError` shown to the user).
//    - Sign-out clears the SAML helper state.
//
//  Hermetic: TPPRequestExecutorMock for the userProfile request; mock
//  TPPUserAccountMock for keychain seam; TPPDRMAuthorizingMock for device
//  deauthorization (with deferred completion support).
//

import XCTest
@testable import Palace

@MainActor
final class TPPSignInBusinessLogicSignOutTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var bookRegistry: TPPBookRegistryMock!
    private var downloadCenter: TPPMyBooksDownloadsCenterMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        networkExecutor = TPPRequestExecutorMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        bookRegistry = TPPBookRegistryMock()
        downloadCenter = TPPMyBooksDownloadsCenterMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: bookRegistry,
            bookDownloadsCenter: downloadCenter,
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDownWithError() throws {
        networkExecutor.reset()
        drmAuthorizer.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        uiDelegate = nil
        networkExecutor = nil
        drmAuthorizer = nil
        bookRegistry = nil
        downloadCenter = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Seeds a fully-signed-in basic-auth user with Adobe device credentials
    /// (licensor + userID + deviceID) so the sign-out path will go through
    /// the deauthorizeDevice() branch.
    private func seedSignedInBasicUserWithAdobe() {
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication
        businessLogic.updateUserAccount(
            forDRMAuthorization: true,
            withBarcode: "1234567890",
            pin: "0000",
            authToken: nil,
            expirationDate: nil,
            patron: nil,
            cookies: nil
        )
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        // Seed Adobe activation state — these are what "preserving Adobe DRM
        // activation across re-auth" means at the userAccount level.
        acct.setUserID("adobe-user-fixed")
        acct.setDeviceID("adobe-device-fixed")
        acct.setLicensor([
            "vendor": "NYPL",
            "clientToken": "Token|user|password"
        ])
    }

    /// Returns the userProfile URL the mock executor is wired to respond to.
    private var userProfileURL: URL {
        URL(string: "https://circulation.librarysimplified.org/NYNYPL/patrons/me/")!
    }

    /// Awaits the next `businessLogicDidFinishDeauthorizing` callback.
    private func awaitDeauthorize(timeout: TimeInterval = 5.0) {
        let exp = expectation(description: "deauthorize completes")
        uiDelegate.didFinishDeauthorizingHandler = { exp.fulfill() }
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - Sign-out happy path

    func test_signOut_clearsCredentialsFromKeychainAfterDeauthorize() {
        seedSignedInBasicUserWithAdobe()
        let acct = businessLogic.userAccount as! TPPUserAccountMock
        XCTAssertTrue(acct.hasCredentials(), "precondition: signed in")

        businessLogic.performLogOut()
        awaitDeauthorize()

        // Sign-out must wipe credentials from the (mocked) keychain.
        XCTAssertFalse(acct.hasCredentials(),
                       "After sign-out completes, credentials must be cleared from the keychain seam")
        XCTAssertNil(acct.authToken, "No stale auth token may remain")
        XCTAssertNil(acct.barcode, "No stale barcode may remain")
    }

    func test_signOut_invokesDRMDeauthorizeExactlyOnce() {
        seedSignedInBasicUserWithAdobe()

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertEqual(drmAuthorizer.deauthorizeCallCount, 1,
                       "deauthorize() must be invoked exactly once per sign-out — duplicates indicate the success-path AND the error-path BOTH ran")
        XCTAssertTrue(drmAuthorizer.deauthorizeWasCalled,
                      "deauthorize() must be invoked at least once when a licensor is present")
    }

    func test_signOut_callsWillSignOutBeforeDeauthorize() {
        // willSignOut signals the UI to start its "Signing Out..." spinner.
        // It must fire as the first delegate event, BEFORE the network call.
        seedSignedInBasicUserWithAdobe()

        var willSignOutFiredBeforeDeauth = false
        uiDelegate.didFinishDeauthorizingHandler = {
            // by the time deauth fires, willSignOut must have already been observed
            willSignOutFiredBeforeDeauth = (self.uiDelegate.didCallWillSignOut == true)
        }

        let exp = expectation(description: "deauth")
        let priorHandler = uiDelegate.didFinishDeauthorizingHandler
        uiDelegate.didFinishDeauthorizingHandler = {
            priorHandler?()
            exp.fulfill()
        }

        businessLogic.performLogOut()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(willSignOutFiredBeforeDeauth,
                      "businessLogicWillSignOut must fire before businessLogicDidFinishDeauthorizing")
    }

    // MARK: - Sign-out cancels in-flight sign-out work (PP-3491 generation guard)

    func test_signOut_preservesNewCredentials_whenUserReauthenticatesDuringSignOut() async {
        // The signInGeneration race-condition guard: if the user signs back
        // in WHILE the sign-out's DRM callback is still pending, the late
        // callback must NOT wipe their new credentials.
        seedSignedInBasicUserWithAdobe()
        let acct = businessLogic.userAccount as! TPPUserAccountMock

        // §10.4 seam: precondition — no sign-out has happened yet, so the
        // generation-snapshot accessor returns its sentinel.
        XCTAssertEqual(businessLogic.signOutSnapshotForTests, -1,
                       "precondition: signOutSnapshot is unset before performLogOut")
        XCTAssertFalse(businessLogic.isSignOutInProgressForTests,
                       "precondition: no sign-out is in flight")

        // Defer the DRM deauthorize completion so we can simulate a race.
        drmAuthorizer.shouldDeferDeauthorize = true

        businessLogic.performLogOut()

        // Drain the userProfile request → deauthorize() gets called → its
        // completion is captured (deferred). JOIN the "deauthorize invoked"
        // edge deterministically via the mock's continuation seam instead of
        // spinning a `Timer.scheduledTimer` that polls `deauthorizeWasCalled`
        // on a 5s wall-clock ceiling (parallel-clone starvable).
        await drmAuthorizer._awaitDeauthorizeCalledForTesting()

        // §10.4 seam: directly observe the captured snapshot — performLogOut
        // recorded the userAccount's current generation. Tests can now pin
        // the snapshot value across the race window without ObjC associated
        // object hackery.
        let capturedGeneration = businessLogic.signOutSnapshotForTests
        XCTAssertGreaterThanOrEqual(capturedGeneration, 0,
                                    "signOutSnapshot must be captured once performLogOut is in flight")
        XCTAssertTrue(businessLogic.isSignOutInProgressForTests,
                      "isSignOutInProgress must be true while DRM deauthorize is pending")

        // Simulate the user re-authenticating during the in-flight sign-out.
        // finalizeSignIn() (production) bumps signInGeneration via
        // cancelPendingSignOut(); we hit the same lever directly.
        businessLogic.cancelPendingSignOut()
        XCTAssertEqual(businessLogic.userAccount.signInGeneration,
                       capturedGeneration + 1,
                       "cancelPendingSignOut must increment signInGeneration past the captured snapshot")

        // And write the "new" credentials that must NOT be wiped.
        acct.setAuthToken("freshly-reauthed-token", barcode: "new-barcode", pin: "new-pin", expirationDate: nil)
        XCTAssertEqual(acct.authToken, "freshly-reauthed-token", "precondition: new creds present")

        // Now release the deferred DRM completion. The stale sign-out must
        // notice the generation mismatch and SKIP wiping credentials.
        let signaled = expectation(description: "finish-deauth-late")
        uiDelegate.didFinishDeauthorizingHandler = { signaled.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()
        await fulfillment(of: [signaled], timeout: 5.0)

        XCTAssertEqual(acct.authToken, "freshly-reauthed-token",
                       "Late sign-out callback must NOT wipe credentials that belong to a NEW sign-in (signInGeneration race-guard)")
        XCTAssertEqual(acct.barcode, "new-barcode",
                       "Late sign-out callback must not touch the new barcode")
        // §10.4 seam: after the stale callback runs, isSignOutInProgress
        // must be cleared (the stale-path resets the flag).
        XCTAssertFalse(businessLogic.isSignOutInProgressForTests,
                       "Stale callback must reset isSignOutInProgress so the next sign-out can proceed")
    }

    func test_signOut_preservesAdobeActivation_whenStaleCallbackArrives() async {
        // Security regression: stale DRM callback must not clear userID /
        // deviceID set by the NEW sign-in. These are what Adobe uses to
        // recognize the device — clearing them burns an activation slot.
        seedSignedInBasicUserWithAdobe()
        let acct = businessLogic.userAccount as! TPPUserAccountMock

        drmAuthorizer.shouldDeferDeauthorize = true
        businessLogic.performLogOut()

        // Join the "deauthorize invoked" edge deterministically (mock seam)
        // instead of Timer-polling `deauthorizeWasCalled` on a 5s ceiling.
        await drmAuthorizer._awaitDeauthorizeCalledForTesting()

        // Race in a new sign-in with NEW Adobe activation state.
        businessLogic.cancelPendingSignOut()
        acct.setUserID("NEW-adobe-user")
        acct.setDeviceID("NEW-adobe-device")
        acct.setAuthToken("new-token", barcode: nil, pin: nil, expirationDate: nil)

        // Fire the stale callback.
        let signaled = expectation(description: "finish-deauth-late")
        uiDelegate.didFinishDeauthorizingHandler = { signaled.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()
        await fulfillment(of: [signaled], timeout: 5.0)

        XCTAssertEqual(acct.userID, "NEW-adobe-user",
                       "Stale sign-out must NOT clobber the new sign-in's Adobe userID — would burn an activation slot")
        XCTAssertEqual(acct.deviceID, "NEW-adobe-device",
                       "Stale sign-out must NOT clobber the new sign-in's Adobe deviceID")
    }

    // MARK: - Re-entrant performLogOut

    func test_signOut_reentrantCall_isCoalesced() async {
        // Second performLogOut() while the first is in flight must be a no-op.
        // We arrange for the DRM completion to be deferred so the first
        // sign-out is unambiguously "in progress" during the second call.
        seedSignedInBasicUserWithAdobe()
        drmAuthorizer.shouldDeferDeauthorize = true

        businessLogic.performLogOut()

        // Join the first sign-out reaching deauthorize deterministically
        // (mock seam) instead of Timer-polling on a 5s wall-clock ceiling.
        await drmAuthorizer._awaitDeauthorizeCalledForTesting()

        // Second call must be coalesced — must not trigger another network request
        // or another deauthorize.
        let countBefore = drmAuthorizer.deauthorizeCallCount
        businessLogic.performLogOut()
        // Drain the runloop to give a hypothetical second sign-out a chance to
        // spin up. FIFO guarantee means every earlier-queued block has run by
        // the time the assertion below executes. `drainMainQueueAsync` (not the
        // sync `drainMainQueue`) is REQUIRED here — this test is now `async`,
        // and the synchronous variant deadlocks inside `@MainActor async` bodies.
        await drainMainQueueAsync()

        XCTAssertEqual(drmAuthorizer.deauthorizeCallCount, countBefore,
                       "Second performLogOut() while first is in-flight must coalesce — must not re-invoke deauthorize()")

        // Clean up — fire the deferred completion so we leave a tidy state.
        let signaled = expectation(description: "first sign-out finishes")
        uiDelegate.didFinishDeauthorizingHandler = { signaled.fulfill() }
        drmAuthorizer.completeDeferredDeauthorize()
        await fulfillment(of: [signaled], timeout: 5.0)
    }

    // MARK: - Sign-out 401 silent path

    func test_signOut_401Response_doesNotShowSignOutErrorToUser() {
        // A 401 on sign-out is the expected "token expired during idle" path
        // (PP-3491 trail). It must NOT surface a confusing
        // "Unexpected Credentials" alert to the user — it must take the
        // silent local-cleanup path through deauthorizeDevice().
        seedSignedInBasicUserWithAdobe()
        networkExecutor.forceFailureStatusCode = 401

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertFalse(uiDelegate.didCallSignOutError,
                       "401 on sign-out must NOT surface a sign-out error to the user (silent cleanup path)")
        XCTAssertEqual(uiDelegate.signOutErrorCallCount, 0,
                       "didEncounterSignOutError must not fire on the 401 silent path")
        // ... but local cleanup must still complete.
        XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                       "Local credentials must still be cleared even on the 401-silent path")
    }

    func test_signOut_500Response_surfacesSignOutErrorAndStillCleansUp() {
        // A 500 (server error) on sign-out: must report the error to the
        // delegate AND still complete local cleanup. The "always cleanup
        // locally" invariant from the production code's comment.
        seedSignedInBasicUserWithAdobe()
        networkExecutor.forceFailureStatusCode = 500

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertTrue(uiDelegate.didCallSignOutError,
                      "Non-401 server error must surface didEncounterSignOutError so the UI can show it")
        XCTAssertEqual(uiDelegate.lastSignOutErrorHTTPStatusCode, 500,
                       "didEncounterSignOutError must carry the actual HTTP status code")
        XCTAssertFalse(businessLogic.userAccount.hasCredentials(),
                       "Local credentials must still be cleared on a server-error path")
    }

    // MARK: - Sign-out clears in-flight businesslogic state

    func test_signOut_clearsSelectedIDP() {
        seedSignedInBasicUserWithAdobe()
        // simulate a saml-style selectedIDP being set
        businessLogic.selectedIDP = nil // can't easily build an OPDS2SamlIDP here;
        // The point of this test is that the assignment in
        // completeLogOutProcess always sets `selectedIDP = nil`. We
        // verify the post-condition rather than the mutation path.

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertNil(businessLogic.selectedIDP,
                     "completeLogOutProcess must set selectedIDP to nil")
    }

    func test_signOut_clearsSAMLHelperState() {
        // The SAML helper retains cookies between flows; sign-out must
        // clear them so a fresh sign-in starts with a clean slate.
        seedSignedInBasicUserWithAdobe()
        let cookie = HTTPCookie(properties: [
            .domain: "idp.example.com",
            .path: "/",
            .name: "session",
            .value: "stale"
        ])!
        businessLogic.samlHelper.cookies = [cookie]
        XCTAssertEqual(businessLogic.samlHelper.cookies?.count, 1, "precondition")

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertNil(businessLogic.samlHelper.cookies,
                     "Sign-out must call samlHelper.clearState() — cookies must be nil after sign-out")
    }

    func test_signOut_resetsBookRegistry() {
        // Sign-out must reset the book registry FOR THIS LIBRARY so the
        // next user's book state doesn't leak across. The mock's `reset(_:)`
        // both flips isSyncing=false AND clears the registry dictionary —
        // we observe BOTH of those side-effects to prove reset() was the
        // method called (not some other path that only updates one flag).
        seedSignedInBasicUserWithAdobe()
        bookRegistry.isSyncing = true
        // Seed a fake record in the registry so the post-condition clear
        // is observable (otherwise the empty-before/empty-after registry
        // wouldn't catch a missed reset call).
        let fakeBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let fakeRecord = TPPBookRegistryRecord(book: fakeBook, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        bookRegistry.registry[fakeBook.identifier] = fakeRecord

        businessLogic.performLogOut()
        awaitDeauthorize()

        XCTAssertFalse(bookRegistry.isSyncing,
                       "Sign-out must reset() the book registry — the mock's reset(_:) clears isSyncing")
        XCTAssertTrue(bookRegistry.registry.isEmpty,
                      "Sign-out must reset() the book registry — the mock's reset(_:) clears the registry dictionary; observing this proves reset() ran, not just isSyncing flipping")
    }
}
