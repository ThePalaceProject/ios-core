//
//  LegacySAMLProblemDocumentPropagationTests.swift
//  PalaceTests
//
//  HelpSpot 17870 — second silent failure surface: when the SAML web-view
//  sheet encounters a problem-document mid-flow, the
//  `SignInWebSheetViewModel.problemFoundHandler` is nil and the sheet just
//  sits there.
//
//  These tests pin the `LegacySAMLWebViewPresenter` wiring: a
//  problem-document handed to the synthesised handler must propagate to
//  `businessLogic.uiDelegate.businessLogic(_:
//  didEncounterValidationError:userFriendlyErrorTitle:andMessage:)` with
//  the problem-doc's title and detail.
//
//  Mutation-gate target: removing the `problemFoundHandler:` argument
//  from the `SignInWebSheetViewModel` construction in
//  `LegacySAMLWebViewPresenter.presentSAMLWebView(...)` or flipping any
//  of the title/detail/fallback wiring must fail at least one test here.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - UI delegate spy for validation-error capture

/// Subclass of the shared mock that adds tracking for
/// `didEncounterValidationError`. We use a subclass instead of editing the
/// shared mock so we don't ripple into other consumers' setup expectations.
private final class ValidationErrorCapturingUIDelegate:
    TPPSignInOutBusinessLogicUIDelegateMock {

    var validationErrorCallCount = 0
    var capturedValidationError: Error?
    var capturedValidationTitle: String?
    var capturedValidationMessage: String?
    var validationErrorExpectation: XCTestExpectation?

    override func businessLogic(_ logic: TPPSignInBusinessLogic,
                                didEncounterValidationError error: Error?,
                                userFriendlyErrorTitle title: String?,
                                andMessage message: String?) {
        validationErrorCallCount += 1
        capturedValidationError = error
        capturedValidationTitle = title
        capturedValidationMessage = message
        validationErrorExpectation?.fulfill()
    }
}

@MainActor
final class LegacySAMLProblemDocumentPropagationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: ValidationErrorCapturingUIDelegate!
    private var networkExecutor: TPPRequestExecutorMock!
    private var urlProvider: TPPURLSettingsProviderMock!
    private var presenter: LegacySAMLWebViewPresenter!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = ValidationErrorCapturingUIDelegate()
        networkExecutor = TPPRequestExecutorMock()
        urlProvider = TPPURLSettingsProviderMock()

        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryMock.tppAccountUUID,
            libraryAccountsProvider: libraryMock,
            urlSettingsProvider: urlProvider,
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: networkExecutor,
            uiDelegate: uiDelegate,
            drmAuthorizer: TPPDRMAuthorizingMock()
        )

        // Construct a presenter wired to the same businessLogic the
        // production init wires up. We test the presenter directly so
        // we don't depend on `SignInWebSheetPresenter.presentOnTop`
        // (which walks the topmost VC). The handler factory under test
        // is the pure piece.
        presenter = LegacySAMLWebViewPresenter(
            universalLinksProvider: urlProvider)
        presenter.businessLogic = businessLogic
    }

    override func tearDown() {
        presenter = nil
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        urlProvider = nil
        networkExecutor = nil
        uiDelegate = nil
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - Test 1: problem document with title + detail → delegate fires

    /// Pins the core fix: a problem-document delivered to the SAML web-view
    /// handler propagates to the businessLogic's UI delegate as a
    /// validation error carrying the problem-doc's title + detail.
    func testSAMLPresenter_problemDocumentWithTitleAndDetail_surfacesToUIDelegate() {
        let expectation = expectation(
            description: "didEncounterValidationError fires")
        uiDelegate.validationErrorExpectation = expectation

        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Patron ID Required",
            "detail": "Your library card number could not be extracted from " +
                      "the SAML response. Please contact your library."
        ])

        let handler = presenter.makeProblemFoundHandler()
        handler(problemDoc)

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(uiDelegate.validationErrorCallCount, 1,
                       "delegate must be called exactly once")
        XCTAssertNotNil(uiDelegate.capturedValidationError,
                        "synthesised Error must be non-nil")
        XCTAssertEqual(uiDelegate.capturedValidationTitle, "Patron ID Required",
                       "title must be the problem-doc title")
        XCTAssertEqual(
            uiDelegate.capturedValidationMessage,
            "Your library card number could not be extracted from " +
            "the SAML response. Please contact your library.",
            "message must be the problem-doc detail")
    }

    // MARK: - Test 2: problem document title-only → message falls back

    /// Pins the title-only fallback shape: if `detail` is missing, the
    /// message slot must still be non-nil so the consumer alert renders.
    func testSAMLPresenter_problemDocumentTitleOnly_surfacesWithFallbackMessage() {
        let expectation = expectation(
            description: "didEncounterValidationError fires")
        uiDelegate.validationErrorExpectation = expectation

        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Library Unavailable"
        ])

        let handler = presenter.makeProblemFoundHandler()
        handler(problemDoc)

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(uiDelegate.validationErrorCallCount, 1)
        XCTAssertEqual(uiDelegate.capturedValidationTitle, "Library Unavailable")
        XCTAssertNotNil(uiDelegate.capturedValidationMessage,
                        "fallback message must be non-nil — UI alert " +
                        "requires a body string")
        XCTAssertFalse(uiDelegate.capturedValidationMessage?.isEmpty ?? true,
                       "fallback message must be non-empty")
    }

    // MARK: - Test 3: nil problem document → delegate fires with generic strings

    /// Pin the nil-problem-doc semantics. We pick "fire with generic
    /// fallback" so the patron always sees an alert when the SAML flow
    /// surfaces a problem — silent failure is exactly what this fix is
    /// preventing.
    func testSAMLPresenter_problemDocumentNil_firesDelegateWithGenericFallback() {
        let expectation = expectation(
            description: "didEncounterValidationError fires with generic strings")
        uiDelegate.validationErrorExpectation = expectation

        let handler = presenter.makeProblemFoundHandler()
        handler(nil)

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(uiDelegate.validationErrorCallCount, 1,
                       "nil problem doc must still surface to the delegate — " +
                       "the whole point of this fix is to eliminate silent failures")
        XCTAssertEqual(uiDelegate.capturedValidationTitle,
                       Strings.Error.loginErrorTitle,
                       "nil problem doc must fall back to generic title")
        XCTAssertEqual(uiDelegate.capturedValidationMessage,
                       Strings.Error.loginErrorDescription,
                       "nil problem doc must fall back to generic description")
    }

    // MARK: - Test 4: error domain check (mutation surface for domain string)

    /// Pin the error domain so a mutation that flips the domain string to
    /// the empty string or another value is caught.
    func testSAMLPresenter_problemDocument_errorDomainIdentifiesSAMLPath() {
        let expectation = expectation(
            description: "didEncounterValidationError fires")
        uiDelegate.validationErrorExpectation = expectation

        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "T", "detail": "D"
        ])

        let handler = presenter.makeProblemFoundHandler()
        handler(problemDoc)

        wait(for: [expectation], timeout: 2.0)

        let nsError = uiDelegate.capturedValidationError as NSError?
        XCTAssertNotNil(nsError, "synthesised error must bridge to NSError")
        XCTAssertEqual(nsError?.domain, "SAML.SignIn.ProblemDocument",
                       "error domain must identify the SAML problem-doc " +
                       "synthesis site for downstream filtering / logging")
    }

    // MARK: - TPPSignInValidationContext bridge (same-file mutation coverage)

    /// Pin `usernameIsEmailKeyboard` predicate against the
    /// `selectedAuthentication?.patronIDKeyboard == .email` definition. Sits
    /// in the SAME file we edited (`LegacySAMLAuthAdapter.swift`), so the
    /// file's mutation kill rate covers the validation bridge too — a
    /// mutation that flips `==` to `!=` MUST fail this test.
    func testSignInBusinessLogic_usernameIsEmailKeyboard_matchesAuthKeyboard() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        let samlAuth = libraryMock.samlAuthentication
        let expectedForSAML = samlAuth.patronIDKeyboard == .email
        XCTAssertEqual(businessLogic.usernameIsEmailKeyboard, expectedForSAML,
                       "predicate must reflect SAML auth's actual keyboard " +
                       "type; mutation `==` → `!=` flips this comparison")

        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        let oauthAuth = libraryMock.oauthAuthentication
        let expectedForOAuth = oauthAuth.patronIDKeyboard == .email
        XCTAssertEqual(businessLogic.usernameIsEmailKeyboard, expectedForOAuth,
                       "predicate must reflect OAuth auth's actual keyboard " +
                       "type; mutation `==` → `!=` flips this comparison")
    }

    /// Pin `pinAllowsAlphanumeric` predicate against the
    /// `selectedAuthentication?.pinKeyboard != .numeric` definition. Catches a
    /// mutation that flips `!=` to `==`.
    func testSignInBusinessLogic_pinAllowsAlphanumeric_isNumericNegation() {
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
        let samlAuth = libraryMock.samlAuthentication
        let expectedAlphanumericSAML = samlAuth.pinKeyboard != .numeric
        XCTAssertEqual(businessLogic.pinAllowsAlphanumeric, expectedAlphanumericSAML,
                       "alphanumeric predicate must be `pinKeyboard != .numeric`; " +
                       "mutation `!=` → `==` flips this")

        businessLogic.selectedAuthentication = libraryMock.oauthAuthentication
        let oauthAuth = libraryMock.oauthAuthentication
        let expectedAlphanumericOAuth = oauthAuth.pinKeyboard != .numeric
        XCTAssertEqual(businessLogic.pinAllowsAlphanumeric, expectedAlphanumericOAuth,
                       "alphanumeric predicate must reflect each auth's pin " +
                       "keyboard; mutation flips both auth verdicts")
    }

    // MARK: - Test 5: weak businessLogic ref doesn't crash when released

    /// Pin the weak-ref lifecycle: if businessLogic is deallocated before
    /// the handler fires, the handler must not crash and must not invoke
    /// the (now-orphaned) delegate. Catches a mutation that flips `weak`
    /// → strong (leak) OR drops the nil-guard.
    func testSAMLPresenter_problemHandler_businessLogicReleased_doesNotCrash() {
        let handler = presenter.makeProblemFoundHandler()

        // Tear down the businessLogic — `weak` should now resolve to nil.
        // Use a fresh local presenter so we don't break setUp's strong
        // references mid-flight; assign the same way the production code
        // does so we exercise the real weak-ref shape.
        let throwawayPresenter = LegacySAMLWebViewPresenter(
            universalLinksProvider: urlProvider)
        autoreleasepool {
            let throwawayBL = TPPSignInBusinessLogic(
                libraryAccountID: libraryMock.tppAccountUUID,
                libraryAccountsProvider: libraryMock,
                urlSettingsProvider: urlProvider,
                bookRegistry: TPPBookRegistryMock(),
                bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
                userAccountProvider: TPPUserAccountMock.self,
                networkExecutor: networkExecutor,
                uiDelegate: uiDelegate,
                drmAuthorizer: TPPDRMAuthorizingMock()
            )
            throwawayPresenter.businessLogic = throwawayBL
        }
        // throwawayBL is now released; the presenter's weak ref must be nil.
        let throwawayHandler = throwawayPresenter.makeProblemFoundHandler()

        let problemDoc = TPPProblemDocument.fromDictionary([
            "title": "Should Not Reach Delegate",
            "detail": "BL released"
        ])

        // Reset the live delegate's count so we can detect any leak.
        uiDelegate.validationErrorCallCount = 0

        // Should not crash, should not call the live delegate.
        throwawayHandler(problemDoc)

        // Give any (incorrect) dispatch a chance to fire. drainMainQueue's FIFO
        // contract guarantees a leaked delegate call would have landed before
        // the no-op block flushes.
        drainMainQueue()

        XCTAssertEqual(uiDelegate.validationErrorCallCount, 0,
                       "released businessLogic must not invoke the delegate — " +
                       "weak ref guard short-circuits")

        // And the live handler still works on the still-alive businessLogic.
        let liveExpectation = expectation(description: "live delegate fires")
        uiDelegate.validationErrorExpectation = liveExpectation
        handler(problemDoc)
        wait(for: [liveExpectation], timeout: 2.0)
        XCTAssertEqual(uiDelegate.capturedValidationTitle,
                       "Should Not Reach Delegate",
                       "live businessLogic delegate still fires normally")
    }
}
