//
//  SignInOAuthErrorPropagationTests.swift
//  PalaceTests
//
//  HelpSpot 17870 — SAML "patron ID extraction" silent failure.
//
//  The OAuth/SAML universal-link redirect handler used to call
//  `completion(nil, ...)` at three failure exits in
//  `TPPSignInBusinessLogic+OAuth.swift`. The PalaceAuth consumer
//  (`TPPSAMLHelper.swift:99-107`) guards `if let error, let errorTitle,
//  let errorMessage { ... }` — so a nil error swallows the alert path
//  even when title/message are present, and the patron sees "tap Login,
//  nothing happens."
//
//  These tests pin the synthesised-error shape at each branch and the
//  parsed-title field-order fix at the payload-error branch. Mutation-gate
//  target: flipping `completion(error, ...)` back to `completion(nil, ...)`
//  must fail at least one test per branch.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class SignInOAuthErrorPropagationTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryMock: TPPLibraryAccountMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!
    private var networkExecutor: TPPRequestExecutorMock!
    private var urlProvider: TPPURLSettingsProviderMock!

    override func setUp() {
        super.setUp()
        TPPUserAccountMock.resetShared()
        libraryMock = TPPLibraryAccountMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
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
        businessLogic.selectedAuthentication = libraryMock.samlAuthentication
    }

    override func tearDown() {
        networkExecutor.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        urlProvider = nil
        networkExecutor = nil
        uiDelegate = nil
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - Branch 1: URL missing universal-links prefix / payload (line 116)

    /// Pins the synthesised-error contract for the "missing payload" exit
    /// (TPPSignInBusinessLogic+OAuth.swift:116). PalaceAuth's
    /// `TPPSAMLHelper.swift:99` guard fires only when ALL three of
    /// (error, errorTitle, errorMessage) are non-nil — so this test would
    /// have caught the original HelpSpot 17870 silent failure.
    func testHandleRedirectURL_missingPayload_synthesizesNonNilErrorWithTitleAndMessage() {
        // URL has correct prefix but no `error=` / `access_token=` payload —
        // hits the `universalLinkRedirectURLContainsPayload(urlStr) == false`
        // branch at OAuth.swift:103-119.
        let prefix = urlProvider.universalLinksURL.absoluteString
        let redirectURL = URL(string: "\(prefix)?some_unrelated_param=foo")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        var capturedTitle: String?
        var capturedMessage: String?
        var completionCallCount = 0
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, title, message in
            capturedError = error
            capturedTitle = title
            capturedMessage = message
            completionCallCount += 1
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(completionCallCount, 1, "completion must fire exactly once")
        XCTAssertNotNil(capturedError,
                        "missing-payload branch must synthesise an Error so " +
                        "TPPSAMLHelper's `if let error, ...` guard fires")
        XCTAssertEqual(capturedTitle, Strings.Error.loginErrorTitle,
                       "title must match Strings.Error.loginErrorTitle")
        XCTAssertEqual(capturedMessage, Strings.Error.loginErrorDescription,
                       "message must match Strings.Error.loginErrorDescription")
    }

    // MARK: - Branch 2: server returned error payload (line 159) — field-order fix

    /// Pins both (a) non-nil error synthesis and (b) the field-swap fix
    /// where the parsed `title` was previously being passed in the `message`
    /// slot. With the fix, the parsed `title` lands in `title`, parsed
    /// `detail` lands in `message`.
    func testHandleRedirectURL_serverReturnsErrorInPayload_synthesizesErrorWithParsedTitleAndDetail() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        // Build a JSON error payload with BOTH title and detail so the fix
        // can be verified at both slots.
        let errorJSON = "{\"title\":\"Patron+ID+Invalid\",\"detail\":\"Library+rejected+the+credentials\"}"
        let encoded = errorJSON
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        // SAML payload is in query; use `?error=` so the parser picks it up
        // and the URL still contains "error" (the
        // `universalLinkRedirectURLContainsPayload` check).
        let redirectURL = URL(string: "\(prefix)?error=\(encoded)")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        var capturedTitle: String?
        var capturedMessage: String?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, title, message in
            capturedError = error
            capturedTitle = title
            capturedMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(capturedError,
                        "payload-error branch must synthesise an Error")
        XCTAssertEqual(capturedTitle, "Patron ID Invalid",
                       "title slot must carry the PARSED title (field-swap fix)")
        XCTAssertEqual(capturedMessage, "Library rejected the credentials",
                       "message slot must carry the parsed detail, not the title")
    }

    /// Edge case for branch 2: payload error JSON has no `detail` field.
    /// Implementation must fall back to a non-nil message so the consumer
    /// guard still fires. Pins the `?? Strings.Error.loginErrorDescription`
    /// fallback semantics.
    func testHandleRedirectURL_serverErrorWithoutDetail_fallsBackToGenericMessage() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        // title only, no detail.
        let errorJSON = "{\"title\":\"Server+Error\"}"
        let encoded = errorJSON
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string: "\(prefix)?error=\(encoded)")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        var capturedTitle: String?
        var capturedMessage: String?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, title, message in
            capturedError = error
            capturedTitle = title
            capturedMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(capturedError,
                        "missing-detail edge case still synthesises an Error")
        XCTAssertEqual(capturedTitle, "Server Error",
                       "parsed title slot is preserved")
        XCTAssertNotNil(capturedMessage,
                        "missing detail must fall back to a non-nil message — " +
                        "TPPSAMLHelper guard requires a non-nil message")
        XCTAssertFalse(capturedMessage?.isEmpty ?? true,
                       "fallback message must be non-empty")
    }

    // MARK: - Branch 3: auth data parse fail (line 180)

    /// Pins the synthesised-error contract for the "parsed payload missing
    /// access_token / patron_info" exit. This is the literal HelpSpot 17870
    /// reproduction shape: SAML response succeeded server-side but the patron
    /// info was malformed; the user is left staring at a hung sheet.
    func testHandleRedirectURL_authDataParseFail_synthesizesNonNilErrorWithTitleAndMessage() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        // URL has the right prefix, the payload check passes ("access_token"
        // and "patron_info" tokens are present in the string), but the
        // patron_info value isn't valid JSON — so the `parsedPatron` guard
        // at OAuth.swift:165-182 fails.
        let bogusPatron = "this_is_not_json".addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string:
            "\(prefix)?access_token=tok&patron_info=\(bogusPatron)")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        var capturedTitle: String?
        var capturedMessage: String?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, title, message in
            capturedError = error
            capturedTitle = title
            capturedMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(capturedError,
                        "parse-fail branch must synthesise an Error — " +
                        "the literal HelpSpot 17870 silent failure")
        XCTAssertNotNil(capturedTitle,
                        "title must be set so consumer guard fires")
        XCTAssertNotNil(capturedMessage,
                        "message must be set so consumer guard fires")
        XCTAssertEqual(capturedTitle, Strings.Error.loginErrorTitle)
        XCTAssertEqual(capturedMessage, Strings.Error.loginErrorDescription)
        XCTAssertNil(businessLogic.authToken,
                     "auth token must not be stored when parsing fails")
    }

    /// Edge case that pins which BRANCH ran. The `universalLinkRedirectURLContainsPayload`
    /// helper checks `urlStr.contains("error") || (contains("access_token") && contains("patron_info"))`.
    /// A URL with only `access_token=` (no `patron_info`, no `error`) MUST hit the
    /// missing-payload branch (line 116) — NOT the parse-fail branch (line 180) —
    /// because the inner AND short-circuits.
    ///
    /// Mutation surface: flipping the inner `&&` to `||` in
    /// `universalLinkRedirectURLContainsPayload` makes that helper return true
    /// for this URL, which would then short-circuit to the parse-fail branch.
    /// We pin the branch identity by asserting the error's localizedDescription
    /// — missing-payload uses `Strings.Error.loginErrorDescription`, parse-fail
    /// uses `"Unable to parse authentication info"`. Different strings catch
    /// the routing flip.
    func testHandleRedirectURL_accessTokenButNoPatronInfo_routesToMissingPayloadBranch() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        // Only access_token; no patron_info; no error.
        // Original code: inner `&&` returns false → outer `||` returns false →
        // missing-payload branch fires.
        // Mutated code (inner `&&` → `||`): inner returns true → outer returns
        // true → falls through to parse-fail branch.
        let redirectURL = URL(string: "\(prefix)?access_token=tok_only")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, _, _ in
            capturedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        let nsError = capturedError as NSError?
        XCTAssertNotNil(nsError, "must synthesise an error")
        // Missing-payload branch sets userInfo with Strings.Error.loginErrorDescription
        // ("An error occurred during the authentication process"). Parse-fail
        // branch sets "Unable to parse authentication info". Pin the branch
        // via the localizedDescription distinction.
        XCTAssertEqual(nsError?.localizedDescription,
                       Strings.Error.loginErrorDescription,
                       "must route to missing-payload branch — a URL without " +
                       "BOTH access_token AND patron_info AND no `error` should " +
                       "fail the payload-contains check, not reach parse-fail")
    }

    // MARK: - Branch 0: notification has no URL (line 96, pre-existing :96 guard)

    /// Defensive coverage for the `notification.object as? URL` guard.
    /// The contract identified this as the implicit fourth branch and the
    /// PR snippet wires a synthesised error here too. Mutation surface: a
    /// regression that returns to `completion?(nil, nil, nil)` MUST fail
    /// this test.
    func testHandleRedirectURL_notificationWithoutURL_synthesizesNonNilError() {
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: "not a URL"   // wrong type — fails `as? URL` cast
        )

        var capturedError: Error?
        var capturedTitle: String?
        var capturedMessage: String?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, title, message in
            capturedError = error
            capturedTitle = title
            capturedMessage = message
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNotNil(capturedError,
                        "no-URL branch must synthesise an Error so the " +
                        "consumer alert path fires")
        XCTAssertEqual(capturedTitle, Strings.Error.loginErrorTitle)
        XCTAssertEqual(capturedMessage, Strings.Error.loginErrorDescription)
    }

    // MARK: - Edge: base64-token kvpair parsing (mutation surface for line 166)

    /// Pin the kvpair-parsing guard `elts.count >= 2`. Base64 tokens contain
    /// `=` padding characters; splitting on `=` gives N>=2 elements; the code
    /// joins all elements after the key. If the guard is mutated to `<= 2`
    /// or `> 2`, tokens with `=` padding (i.e. realistic JWT/base64 tokens)
    /// are silently dropped or fully skipped, and the success path breaks.
    func testHandleRedirectURL_accessTokenWithEqualsPadding_parsesCorrectly() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        // Realistic shape: a JWT-style token with a trailing `=` would have
        // count == 3 when split on `=`. Use a multi-segment token to pin
        // the `>= 2` guard.
        let tokenWithEquals = "header.payload.signature=="
        let patronJSON = "{\"name\":\"Edge\"}"
        let encoded = patronJSON.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string:
            "\(prefix)?access_token=\(tokenWithEquals)&patron_info=\(encoded)")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, _, _ in
            capturedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNil(capturedError,
                     "happy-path with base64-padded token must succeed; if " +
                     "the kvpair guard is broken, parse-fail branch fires")
        XCTAssertEqual(businessLogic.authToken, tokenWithEquals,
                       "token with `=` padding must be preserved verbatim — " +
                       "code joins all post-key segments to handle this")
    }

    // MARK: - Happy-path regression guard

    /// Pins that the happy path still completes with `(nil, nil, nil)` —
    /// i.e. our error-synthesis changes are surgical to the failure exits
    /// and do not accidentally fire on the success path.
    func testHandleRedirectURL_successPath_completionFiresWithNilError() {
        let prefix = urlProvider.universalLinksURL.absoluteString
        let patronJSON = "{\"name\":\"Test+Patron\"}"
        let encoded = patronJSON.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed)!
        let redirectURL = URL(string:
            "\(prefix)?access_token=valid-tok&patron_info=\(encoded)")!
        let notification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: redirectURL
        )

        var capturedError: Error?
        let expectation = expectation(description: "completion fires")

        businessLogic.handleRedirectURL(notification) { error, _, _ in
            capturedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        XCTAssertNil(capturedError,
                     "happy path must complete with nil error — error " +
                     "synthesis is scoped to failure exits only")
        XCTAssertEqual(businessLogic.authToken, "valid-tok",
                       "auth token must be stored on success")
    }
}
