//
//  BorrowOperationReauthLoopTests.swift
//  PalaceTests
//
//  PP-5359: a borrow that keeps failing must re-authenticate at most once
//  and then show an error, and a failure that is not about credentials must
//  not touch the patron's sign-in state at all.
//

import XCTest
import PalaceCatalog
@testable import Palace
@testable import PalaceAuth
import PalaceBookModel

@MainActor
final class BorrowOperationReauthLoopTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var userAccount: TPPUserAccountMock!
    private var operation: BorrowOperation!
    private var book: TPPBook!
    private var fetchError: Error!
    /// When set, every attempt after the first fails with this instead.
    private var retryError: Error?
    /// When true, every attempt after the first borrows the book.
    private var retrySucceeds = false
    private var fetchCount = 0
    private var alertCount = 0
    private var lastRetryAction: (() -> Void)?
    private var signInModalCount = 0
    private var oidcReauthCount = 0
    private var oidcReauthResult = false
    /// What the spy sign-in modal does when presented.
    private var onSignInModal: ((@escaping () -> Void) -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        fetchCount = 0
        retryError = nil
        retrySucceeds = false
        alertCount = 0
        lastRetryAction = nil
        signInModalCount = 0
        oidcReauthCount = 0
        oidcReauthResult = false
        onSignInModal = nil
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        operation = nil
        bookRegistry = nil
        userAccount = nil
        book = nil
        try super.tearDownWithError()
    }

    private func makeOperation(coordinator: AuthCoordinator?) {
        let account = userAccount!
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: ErrorActivityTracker(),
            debugSettings: DebugSettings(),
            userRetryTracker: UserRetryTracker(),
            userAccountProvider: { account },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { [weak self] _, _, _ in
                guard let self else { throw NSError(domain: "test", code: -1) }
                self.fetchCount += 1
                if self.fetchCount > 1, self.retrySucceeds { return self.book }
                if self.fetchCount > 1, let retryError = self.retryError { throw retryError }
                throw self.fetchError
            },
            presentBorrowErrorAlert: { [weak self] _, _, _, _, _, retry in
                self?.alertCount += 1
                self?.lastRetryAction = retry
            },
            publishBorrowError: { _ in },
            presentSignInModal: { [weak self] completion in
                self?.signInModalCount += 1
                self?.onSignInModal?(completion)
            },
            attemptOIDCReauth: { [weak self] in
                guard let self else { return false }
                self.oidcReauthCount += 1
                // Bounded so a regression shows as extra attempts, not a hang.
                return self.oidcReauthResult && self.oidcReauthCount <= 3
            },
            authCoordinator: coordinator
        )
    }

    private func signIn(_ auth: AccountDetails.Authentication) {
        userAccount._authDefinition = auth
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
    }

    /// The shape OPDSFeedService throws: a bridged PalaceError carrying the
    /// server's problem document.
    private func problemError(_ type: String) throws -> NSError {
        let data = try JSONSerialization.data(withJSONObject: ["type": type])
        let doc = try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
        return NSError(domain: "Palace.PalaceError", code: 0, userInfo: ["problemDocument": doc as Any])
    }

    private func borrow() async {
        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("a failing borrow must throw")
        } catch {}
    }

    // MARK: - One re-authentication per borrow tap

    /// The identity provider's sheet completes at once when its session is still
    /// valid, so a borrow that keeps failing used to re-prompt without end.
    func testBorrow_SAML_whenTheRetryAlsoFails_reauthenticatesOnceThenShowsAnError() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1, "one sign-in for one borrow tap")
        XCTAssertEqual(fetchCount, 2, "the borrow is retried once after signing in")
        XCTAssertEqual(alertCount, 1, "the retry's failure is shown to the patron")
    }

    /// Silent OIDC re-authentication needs no patron action, so without the
    /// armed breaker the loop would run with nobody to stop it.
    func testBorrow_OIDCSilentReauthSucceeds_retryFails_reauthenticatesOnceThenShowsAnError() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.oidc)
        oidcReauthResult = true
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()

        XCTAssertEqual(oidcReauthCount, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(alertCount, 1)
    }

    /// After signing in, a browser-sign-in account has credentials, so a
    /// cleared breaker would send the failed retry straight back to sign-in.
    func testBorrow_signedOutSAML_signInSucceeds_retryFails_promptsOnceThenShowsAnError() async throws {
        makeOperation(coordinator: nil)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        let account = userAccount!
        var shown = 0
        onSignInModal = { completion in
            shown += 1
            guard shown <= 3 else { return }  // bounded: a regression adds attempts, not a hang
            account._credentials = .barcodeAndPin(barcode: "b", pin: "p")
            completion()
        }
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()
        await operation._awaitPendingRetriesForTesting()

        XCTAssertEqual(signInModalCount, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(alertCount, 1)
    }

    func testBorrow_SAMLWithoutCoordinator_modalSucceeds_retryFails_promptsOnceThenShowsAnError() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.saml)
        var shown = 0
        onSignInModal = { completion in
            shown += 1
            if shown <= 3 { completion() }  // bounded: a regression adds attempts, not a hang
        }
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()
        await operation._awaitPendingRetriesForTesting()

        XCTAssertEqual(signInModalCount, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(alertCount, 1)
    }

    /// The caller releases the borrow's download slot only when the borrow
    /// fails; a retry that borrowed (and may have started the download) must
    /// therefore report success, not the original error.
    func testBorrow_SAML_retryAfterSignInSucceeds_returnsTheBookInsteadOfThrowing() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)
        retrySucceeds = true

        let borrowed = try await operation.borrowAsync(book, attemptDownload: false)

        XCTAssertEqual(borrowed.identifier, book.identifier)
        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(alertCount, 0)
        XCTAssertFalse(BorrowOperation.isBorrowReauthGatedForTesting(book.identifier),
                       "a successful borrow clears the breaker")
    }

    func testBorrow_OIDCSilentReauthSucceeds_retrySucceeds_returnsTheBook() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.oidc)
        oidcReauthResult = true
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)
        retrySucceeds = true

        let borrowed = try await operation.borrowAsync(book, attemptDownload: false)

        XCTAssertEqual(borrowed.identifier, book.identifier)
        XCTAssertEqual(oidcReauthCount, 1)
        XCTAssertEqual(alertCount, 0)
    }

    func testBorrow_OIDCSilentReauthFails_coordinatorSignInSucceeds_retrySucceeds_returnsTheBook() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .oidc, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.oidc)
        oidcReauthResult = false
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)
        retrySucceeds = true

        let borrowed = try await operation.borrowAsync(book, attemptDownload: false)

        XCTAssertEqual(borrowed.identifier, book.identifier)
        XCTAssertEqual(oidcReauthCount, 1)
        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(alertCount, 0)
    }

    // MARK: - The breaker after a failed retry

    /// Retry in the error alert is the patron asking again, so it may sign in again.
    func testRetryButton_afterAFailedReauthRetry_clearsTheBreaker() async throws {
        let (coordinator, _, _, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)
        retryError = PalaceError.network(.timeout)

        await borrow()
        XCTAssertTrue(BorrowOperation.isBorrowReauthGatedForTesting(book.identifier),
                      "after a failed retry the book is gated")
        let retry = try XCTUnwrap(lastRetryAction, "the retry's timeout offers Retry")

        retry()

        XCTAssertFalse(BorrowOperation.isBorrowReauthGatedForTesting(book.identifier))
    }

    func testBreaker_afterAFailedReauthRetry_staysArmedForTheNextTap() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()
        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1, "a second tap without Retry does not re-prompt")
        XCTAssertEqual(alertCount, 2)
    }

    // MARK: - Failures that are not about credentials

    func testBorrow_SAML_loanLimit_showsTheErrorWithoutSigningIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypePatronLoanLimit)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 0)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(alertCount, 1)
        XCTAssertEqual(userAccount.authState, .loggedIn)
    }

    func testBorrow_basicToken_loanLimit_keepsTheAccountSignedIn() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.basicToken)
        fetchError = try problemError(TPPProblemDocument.TypePatronLoanLimit)

        await borrow()

        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "a loan limit is not a credentials problem; marking it stale prompts sign-in elsewhere")
        XCTAssertEqual(alertCount, 1)
        XCTAssertEqual(signInModalCount, 0)
    }

    func testBorrow_basicToken_timeout_keepsTheAccountSignedIn() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.basicToken)
        fetchError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        await borrow()

        XCTAssertEqual(userAccount.authState, .loggedIn)
        XCTAssertEqual(alertCount, 1)
    }

    func testBorrow_basicToken_noActiveLoan_isNotAnAuthError() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.basicToken)
        fetchError = try problemError(TPPProblemDocument.TypeNoActiveLoan)

        await borrow()

        XCTAssertEqual(userAccount.authState, .loggedIn)
        XCTAssertEqual(alertCount, 1)
    }

    func testBorrow_SAMLWithoutCredentials_noActiveLoan_isNotAnAuthError() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        fetchError = try problemError(TPPProblemDocument.TypeNoActiveLoan)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 0)
        XCTAssertEqual(signInModalCount, 0)
        XCTAssertEqual(alertCount, 1)
    }

    /// The token-refresh failure path already marks the account stale and
    /// presents sign-in itself (TPPNetworkExecutor.refreshTokenAndResume);
    /// the borrow shows the server's reason rather than a second prompt.
    func testBorrow_basicToken_failedRefreshWithServerDocument_showsTheErrorWithoutASecondPrompt() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.basicToken)
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "http://librarysimplified.org/terms/problem/credentials-expired", "title": "Expired Card"])
        let doc = try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
        fetchError = NSError.makeFromProblemDocument(doc, domain: TPPErrorLogger.clientDomain,
                                                     code: TPPErrorCode.invalidCredentials.rawValue,
                                                     userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])

        await borrow()

        XCTAssertEqual(signInModalCount, 0)
        XCTAssertEqual(alertCount, 1)
        XCTAssertEqual(userAccount.authState, .loggedIn, "the borrow does not re-classify the refresh failure as its own")
        XCTAssertFalse(BorrowOperation.isBorrowReauthGatedForTesting(book.identifier))
    }

    /// The server's credentials types: these mean the stored credentials were
    /// refused, so signing in again is the fix.
    func testBorrow_SAML_credentialsRefusedDocuments_routeToSignIn() async throws {
        let types = [
            TPPProblemDocument.TypeInvalidCredentials,
            "http://librarysimplified.org/terms/problem/invalid-credentials",
            "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
            "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
        ]
        for type in types {
            BorrowOperation.clearAllBorrowReauthState()
            let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
            makeOperation(coordinator: coordinator)
            signIn(try SyntheticAuthDef.saml)
            fetchError = try problemError(type)

            await borrow()

            XCTAssertEqual(modal.presentCallCount, 1, "\(type) should prompt sign-in")
        }
    }

    /// An expired, suspended or blocked card, or a limit: signing in cannot fix
    /// these, so the server's text is shown and sign-in state is untouched.
    func testBorrow_SAML_documentsSigningInCannotFix_showTheError() async throws {
        let types = [
            TPPProblemDocument.TypePatronLoanLimit,
            TPPProblemDocument.TypePatronHoldLimit,
            "http://librarysimplified.org/terms/problem/credentials-expired",
            TPPProblemDocument.TypeCredentialsSuspended,
            "http://librarysimplified.org/terms/problem/credentials-blocked-by-policy",
            "http://palaceproject.io/terms/problem/auth/unrecoverable/patron/no-access",
        ]
        for type in types {
            BorrowOperation.clearAllBorrowReauthState()
            alertCount = 0
            let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
            makeOperation(coordinator: coordinator)
            signIn(try SyntheticAuthDef.saml)
            fetchError = try problemError(type)

            await borrow()

            XCTAssertEqual(modal.presentCallCount, 0, "\(type) should not prompt sign-in")
            XCTAssertEqual(alertCount, 1, "\(type) should show the error")
            XCTAssertEqual(userAccount.authState, .loggedIn, "\(type) should leave sign-in state alone")
        }
    }

    func testBorrow_loanAlreadyExists_whenTheBookIsOnLoan_isSuppressed() async throws {
        makeOperation(coordinator: nil)
        signIn(try SyntheticAuthDef.basicToken)
        bookRegistry.addBook(book, state: .downloadSuccessful)
        fetchError = try problemError(TPPProblemDocument.TypeLoanAlreadyExists)

        await borrow()

        XCTAssertEqual(alertCount, 0, "the patron already has the loan")
        XCTAssertEqual(userAccount.authState, .loggedIn)
    }

    // MARK: - Real credentials failures still re-authenticate

    func testBorrow_SAML_invalidCredentials_routesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(alertCount, 0, "the patron cancelled sign-in; no error alert races the modal")
    }

    func testBorrow_SAML_recoverableAuthDocument_routesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = try problemError("http://palaceproject.io/terms/problem/auth/recoverable/token/expired")

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }

    func testBorrow_SAML_invalidCredentialsCodeWithoutDocument_routesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.invalidCredentials.rawValue)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }

    /// Some paths strip the problem document, leaving only the status.
    func testBorrow_SAML_bareUnauthorized_routesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = PalaceError.network(.unauthorized)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }

    func testBorrow_SAML_bareForbidden_routesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        signIn(try SyntheticAuthDef.saml)
        fetchError = PalaceError.network(.forbidden)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }
}

private enum SyntheticAuthDef {

    private static func make(_ json: String) throws -> AccountDetails.Authentication {
        let docAuth = try JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    static var saml: AccountDetails.Authentication {
        get throws {
            try make("""
            {"type": "http://librarysimplified.org/authtype/SAML-2.0", "description": "SAML",
             "links": [{"rel": "authenticate", "href": "https://idp.example.com/saml"}]}
            """)
        }
    }

    static var oidc: AccountDetails.Authentication {
        get throws {
            try make("""
            {"type": "http://palaceproject.io/authtype/OpenIDConnect", "description": "OIDC",
             "links": [{"rel": "authenticate", "href": "https://idp.example.com/oidc/authorize"}]}
            """)
        }
    }

    static var basicToken: AccountDetails.Authentication {
        get throws {
            try make("""
            {"type": "http://thepalaceproject.org/authtype/basic-token", "description": "Library Barcode + Token",
             "links": [{"rel": "authenticate", "href": "https://cm.example.com/patrons/me/token/"}]}
            """)
        }
    }
}
