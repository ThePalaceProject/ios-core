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
    private var fetchCount = 0
    private var alertCount = 0
    private var signInModalCount = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        BorrowOperation.clearAllBorrowReauthState()
        bookRegistry = TPPBookRegistryMock()
        userAccount = TPPUserAccountMock()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        fetchCount = 0
        alertCount = 0
        signInModalCount = 0
    }

    override func tearDownWithError() throws {
        BorrowOperation.clearAllBorrowReauthState()
        operation = nil
        try super.tearDownWithError()
    }

    private func makeOperation(coordinator: AuthCoordinator?) {
        let account = userAccount!
        operation = BorrowOperation(
            bookRegistry: bookRegistry,
            downloadAnnouncementService: DownloadAnnouncementService(),
            errorActivityTracker: .shared,
            debugSettings: DebugSettings(),
            userRetryTracker: .shared,
            userAccountProvider: { account },
            adobeDRMService: AdobeDRMService.shared,
            fetchBook: { [weak self] _, _, _ in
                guard let self else { throw NSError(domain: "test", code: -1) }
                self.fetchCount += 1
                throw self.fetchError
            },
            presentBorrowErrorAlert: { [weak self] _, _, _, _, _, _ in self?.alertCount += 1 },
            presentSignInModal: { [weak self] _ in self?.signInModalCount += 1 },
            attemptOIDCReauth: { false },
            authCoordinator: coordinator
        )
    }

    private func problemError(_ type: String, code: Int) throws -> NSError {
        let data = try JSONSerialization.data(withJSONObject: ["type": type])
        let doc = try XCTUnwrap(TPPProblemDocument.fromProblemResponseData(data))
        return NSError(domain: "test", code: code, userInfo: ["problemDocument": doc as Any])
    }

    private func borrow() async {
        do {
            _ = try await operation.borrowAsync(book, attemptDownload: false)
            XCTFail("a failing borrow must throw")
        } catch {}
    }

    // MARK: - Browser sign-in: the retry after re-authentication

    /// The identity provider's sheet completes at once when its session is still
    /// valid, so a borrow that keeps failing used to re-prompt without end.
    func testBorrow_SAML_whenTheRetryAlsoFails_reauthenticatesOnceThenShowsAnError() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials, code: 401)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1, "one sign-in for one borrow tap")
        XCTAssertEqual(fetchCount, 2, "the borrow is retried once after signing in")
        XCTAssertEqual(alertCount, 1, "the retry's failure is shown to the patron")
    }

    // MARK: - Failures that are not about credentials

    func testBorrow_SAML_loanLimit_showsTheErrorWithoutSigningIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: true)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = try problemError(TPPProblemDocument.TypePatronLoanLimit, code: 403)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 0)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(alertCount, 1)
        XCTAssertEqual(userAccount.authState, .loggedIn)
    }

    func testBorrow_basicToken_loanLimit_keepsTheAccountSignedIn() async throws {
        makeOperation(coordinator: nil)
        userAccount._authDefinition = try SyntheticAuthDef.basicToken
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = try problemError(TPPProblemDocument.TypePatronLoanLimit, code: 403)

        await borrow()

        XCTAssertEqual(userAccount.authState, .loggedIn,
                       "a loan limit is not a credentials problem; marking it stale prompts sign-in elsewhere")
        XCTAssertEqual(alertCount, 1)
        XCTAssertEqual(signInModalCount, 0)
    }

    func testBorrow_basicToken_serverErrorWithoutProblemDocument_keepsTheAccountSignedIn() async throws {
        makeOperation(coordinator: nil)
        userAccount._authDefinition = try SyntheticAuthDef.basicToken
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        await borrow()

        XCTAssertEqual(userAccount.authState, .loggedIn)
        XCTAssertEqual(alertCount, 1)
    }

    // MARK: - A real credentials failure still re-authenticates

    /// Some paths strip the problem document, leaving only the status.
    func testBorrow_SAML_bareUnauthorized_stillRoutesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = PalaceError.network(.unauthorized)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }

    func testBorrow_SAML_bareForbidden_stillRoutesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = PalaceError.network(.forbidden)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
    }

    func testBorrow_SAML_invalidCredentials_stillRoutesToSignIn() async throws {
        let (coordinator, _, modal, _, _) = SpyAuthCoordinatorFactory.make(mechanism: .saml, stubModalResult: false)
        makeOperation(coordinator: coordinator)
        userAccount._authDefinition = try SyntheticAuthDef.saml
        userAccount._credentials = .barcodeAndPin(barcode: "b", pin: "p")
        userAccount.setAuthState(.loggedIn)
        fetchError = try problemError(TPPProblemDocument.TypeInvalidCredentials, code: 401)

        await borrow()

        XCTAssertEqual(modal.presentCallCount, 1)
        XCTAssertEqual(alertCount, 0, "the patron cancelled sign-in; no error alert races the modal")
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

    static var basicToken: AccountDetails.Authentication {
        get throws {
            try make("""
            {"type": "http://thepalaceproject.org/authtype/basic-token", "description": "Library Barcode + Token",
             "links": [{"rel": "authenticate", "href": "https://cm.example.com/patrons/me/token/"}]}
            """)
        }
    }
}
