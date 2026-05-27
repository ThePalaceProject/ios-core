//
//  AuthErrorClassifierTests.swift
//  PalaceAuthTests
//
//  Per-row unit tests for `AuthErrorClassifier.classify(...)`.
//  Every row in `docs/3.2.0-auth-idp-catalog.md` § 1–7 that has a
//  grounded expected outcome maps to a test in this file. Property-based
//  fuzzing lives in `AuthErrorClassifierPropertyTests`.
//
//  Mutation gate: AuthErrorClassifier.swift must hit 100% kill rate via
//  `scripts/palace_mutate.py`. These tests are the kill harness — every
//  conditional branch in the classifier MUST have at least one positive
//  + one negative test below.
//

import XCTest
import PalaceCatalog
@testable import PalaceAuth

final class AuthErrorClassifierTests: XCTestCase {

    private let testURL = URL(string: "https://gorgon.palaceproject.io/library/loans")!
    private let crossDomainURL = URL(string: "https://library.biblioboard.com/content/book.epub")!
    private let sister = URL(string: "https://cdn.palaceproject.io/content/book.epub")!

    private let classifier = AuthErrorClassifier()

    // MARK: - Rule 1: nil response -> .networkError

    func testClassify_nilResponse_returnsNetworkError() {
        let outcome = classifier.classify(
            response: nil,
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .networkError)
    }

    func testClassify_nilResponse_withProblemDoc_returnsNetworkError() {
        // problem doc presence is meaningless without an HTTP response
        let outcome = classifier.classify(
            response: nil,
            problemDocument: recoverableTokenExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .networkError)
    }

    // MARK: - Rule 2: 2xx -> .ok

    func testClassify_basic200_returnsOk() {
        let outcome = classifier.classify(
            response: httpResponse(status: 200),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .ok)
    }

    func testClassify_204NoContent_returnsOk() {
        let outcome = classifier.classify(
            response: httpResponse(status: 204),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .ok)
    }

    func testClassify_299EdgeOfSuccess_returnsOk() {
        // boundary test — kills any "<200 || >=299" mutation
        let outcome = classifier.classify(
            response: httpResponse(status: 299),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .ok)
    }

    // MARK: - Rule 3: 5xx -> .serverError(status:)

    func testClassify_500_returnsServerError500() {
        let outcome = classifier.classify(
            response: httpResponse(status: 500),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 500))
    }

    func testClassify_503_returnsServerError503() {
        let outcome = classifier.classify(
            response: httpResponse(status: 503),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 503))
    }

    func testClassify_599UpperBoundOf5xx_returnsServerError599() {
        // boundary test — kills any "<500 || >599" mutation
        let outcome = classifier.classify(
            response: httpResponse(status: 599),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 599))
    }

    // MARK: - Rule 4: cross-domain 401 -> .ok (preserves CDN guard)

    func testClassify_401FromCrossDomain_returnsOk() {
        // CRITICAL — replaces URLResponseAuthenticationTests.test401FromDifferentDomain
        let outcome = classifier.classify(
            response: httpResponse(url: crossDomainURL, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .ok)
    }

    func testClassify_401FromCrossDomain_withProblemDoc_returnsOk() {
        // Even if the third-party returns a problem doc, it's not our
        // credentials — preserves URLResponseAuthenticationTests.testProblemDocFromDifferentDomain
        let outcome = classifier.classify(
            response: httpResponse(url: crossDomainURL, status: 401, mime: "application/problem+json"),
            problemDocument: recoverableTokenExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .ok)
    }

    func testClassify_401FromSisterSubdomain_returnsReauthRequired() {
        // cdn.palaceproject.io vs gorgon.palaceproject.io = same base domain
        let outcome = classifier.classify(
            response: httpResponse(url: sister, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    // MARK: - Rule 5: 401 + recoverable problem doc -> .reauthRequired(specific)

    func testClassify_401WithTokenExpired_returnsReauthRequiredExpiredToken() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: recoverableTokenExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .expiredToken))
    }

    func testClassify_401WithSamlSessionExpired_returnsReauthRequiredSamlSessionExpired() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: recoverableSamlSessionExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .samlSessionExpired))
    }

    func testClassify_401WithSamlBearerTokenInvalid_returnsReauthRequiredSamlSessionExpired() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: recoverableSamlBearerTokenInvalidDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .samlSessionExpired))
    }

    func testClassify_401WithNoActiveLoan_returnsReauthRequiredExpiredToken() {
        // TPPProblemDocument.TypeNoActiveLoan — IdP-agnostic recoverable.
        // The coordinator's IdP-dispatch decides if this routes to a
        // silent token refresh (OAuth/Token) or a SAML/OIDC modal.
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: noActiveLoanDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .expiredToken))
    }

    func testClassify_401WithGenericRecoverable_returnsReauthRequiredUnknown401() {
        // A recoverable type the classifier doesn't have a specific
        // mapping for must still surface as reauth-required (just with
        // the unknown hint). Prevents a future recoverable type from
        // silently regressing to .ok.
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: recoverableGenericDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    // MARK: - Rule 6: 401 + unrecoverable -> .reauthRequired(.invalidCredentials)

    func testClassify_401WithUnrecoverableInvalidCredentials_returnsReauthRequiredInvalidCredentials() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: unrecoverableInvalidCredentialsDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .invalidCredentials))
    }

    func testClassify_401WithUnrecoverableNoAccess_returnsReauthRequiredInvalidCredentials() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: unrecoverableNoAccessDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .invalidCredentials))
    }

    // MARK: - Rule 7: 401 + legacy credentials-invalid -> .invalidCredentials

    func testClassify_401WithLegacyCredentialsInvalidType_returnsReauthRequiredInvalidCredentials() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: legacyCredentialsInvalidDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .invalidCredentials))
    }

    // MARK: - Rule 8: bare 401 -> .reauthRequired(.unknown401)

    func testClassify_bare401_returnsReauthRequiredUnknown401() {
        let outcome = classifier.classify(
            response: httpResponse(status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    func testClassify_bare401_withNilOriginalURL_returnsReauthRequiredUnknown401() {
        // Backward-compat: callers that don't track originalRequestURL
        // (legacy ObjC paths) still get the bare-401 behavior.
        let outcome = classifier.classify(
            response: httpResponse(status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: nil
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    // MARK: - Rule 9: 401 + malformed body -> .reauthRequired(.unknown401)

    func testClassify_401WithMalformedProblemDocBody_returnsReauthRequiredUnknown401() {
        // problem-doc MIME but the parser failed (problemDocument arg
        // is nil); body bytes are garbage. Classifier must NOT crash and
        // must fall back to bare-401 semantics.
        let body = "not json {{{".data(using: .utf8)
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/problem+json"),
            problemDocument: nil,
            body: body,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    func testClassify_401WithOPDSAuthMime_returnsReauthRequiredUnknown401() {
        // OPDS authentication document responses are auth-challenge
        // surfaces — treat as reauth-required (the legacy extension
        // returned `true` for these too).
        let outcome = classifier.classify(
            response: httpResponse(status: 401, mime: "application/vnd.opds.authentication.v1.0+json"),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    func testClassify_400WithOPDSAuthMime_returnsReauthRequiredUnknown401() {
        // Mirrors URLResponseAuthenticationTests.testHTTPURLResponse_withOPDSAuthMimeType_andNon2xxStatus_returnsTrue
        // A 400 with OPDS auth MIME still indicates the server is
        // challenging the client — we route through reauth.
        let outcome = classifier.classify(
            response: httpResponse(status: 400, mime: "application/vnd.opds.authentication.v1.0+json"),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401))
    }

    // MARK: - Rule 10: 403 + license-expired -> .forbidden(.licenseExpired)

    func testClassify_403WithLicenseExpired_returnsForbiddenLicenseExpired() {
        let outcome = classifier.classify(
            response: httpResponse(status: 403, mime: "application/problem+json"),
            problemDocument: licenseExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .forbidden(reason: .licenseExpired))
    }

    func testClassify_403WithGeoRestriction_returnsForbiddenGeoRestriction() {
        let outcome = classifier.classify(
            response: httpResponse(status: 403, mime: "application/problem+json"),
            problemDocument: geoRestrictionDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .forbidden(reason: .geoRestriction))
    }

    func testClassify_403WithAccountSuspended_returnsForbiddenAccountSuspended() {
        let outcome = classifier.classify(
            response: httpResponse(status: 403, mime: "application/problem+json"),
            problemDocument: accountSuspendedDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .forbidden(reason: .accountSuspended))
    }

    func testClassify_403WithAccountSuspendedURLPath_returnsForbiddenAccountSuspended() {
        // Kills the "or /account-suspended" alternation: distinct from
        // TypeCredentialsSuspended which matches the first alternation only.
        // The IdP catalog § Section 2 lists "account-suspended" as a
        // distinct OAuth-intermediary 403 pattern.
        let doc = TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/account-suspended",
            "title": "Account suspended",
            "status": 403
        ])
        let outcome = classifier.classify(
            response: httpResponse(status: 403, mime: "application/problem+json"),
            problemDocument: doc,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .forbidden(reason: .accountSuspended))
    }

    // MARK: - Rule 11: 403 + recoverable -> .reauthRequired(.invalidCredentials)

    func testClassify_403WithRecoverableProblemDoc_returnsReauthRequiredInvalidCredentials() {
        // A 403 carrying a recoverable auth path is an edge — server is
        // saying "this is fixable" while returning 403. Coordinator
        // surfaces re-auth (it can't make things worse).
        let outcome = classifier.classify(
            response: httpResponse(status: 403, mime: "application/problem+json"),
            problemDocument: recoverableTokenExpiredDoc(),
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .invalidCredentials))
    }

    // MARK: - Rule 12: 403 bare -> .forbidden(.unknown403)

    func testClassify_403Bare_returnsForbiddenUnknown403() {
        let outcome = classifier.classify(
            response: httpResponse(status: 403),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .forbidden(reason: .unknown403))
    }

    // MARK: - Rule 13: other 4xx -> .serverError(status:)

    func testClassify_400Bare_returnsServerError400() {
        let outcome = classifier.classify(
            response: httpResponse(status: 400),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 400))
    }

    func testClassify_404_returnsServerError404() {
        let outcome = classifier.classify(
            response: httpResponse(status: 404),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 404))
    }

    func testClassify_422_returnsServerError422() {
        let outcome = classifier.classify(
            response: httpResponse(status: 422),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 422))
    }

    // MARK: - 3xx redirect handling (not auth's concern -> serverError)

    func testClassify_302Redirect_returnsServerError302() {
        // Redirects shouldn't typically reach the classifier (URLSession
        // follows them by default), but if one does, it isn't a 2xx, 4xx
        // auth case, or 5xx — bucket into serverError so it doesn't
        // silently map to .ok.
        let outcome = classifier.classify(
            response: httpResponse(status: 302),
            problemDocument: nil,
            body: nil,
            originalRequestURL: testURL
        )
        XCTAssertEqual(outcome, .serverError(status: 302))
    }

    // MARK: - Fixtures

    private func httpResponse(
        url: URL? = nil,
        status: Int,
        mime: String? = nil
    ) -> HTTPURLResponse {
        let targetURL = url ?? testURL
        var headers: [String: String] = [:]
        if let mime { headers["Content-Type"] = mime }
        guard let response = HTTPURLResponse(
            url: targetURL,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ) else {
            XCTFail("HTTPURLResponse construction failed for status \(status)")
            // Force a value rather than a force-unwrap; tests will already have failed.
            return HTTPURLResponse()
        }
        return response
    }

    // MARK: - Problem document fixtures (recoverable)

    private func recoverableTokenExpiredDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/token/expired",
            "title": "Access token expired",
            "status": 401
        ])
    }

    private func recoverableSamlSessionExpiredDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/session-expired",
            "title": "SAML session expired",
            "status": 401
        ])
    }

    private func recoverableSamlBearerTokenInvalidDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/saml/bearer-token-invalid",
            "title": "Invalid SAML bearer token",
            "status": 401
        ])
    }

    private func recoverableGenericDoc() -> TPPProblemDocument {
        // Recoverable category but a type the classifier doesn't have a
        // SAML/token-specific mapping for. Forces the .unknown401 branch
        // inside the recoverable arm.
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/recoverable/some-future-thing",
            "title": "Future recoverable",
            "status": 401
        ])
    }

    private func noActiveLoanDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeNoActiveLoan,
            "title": "No active loan",
            "status": 401
        ])
    }

    // MARK: - Problem document fixtures (unrecoverable)

    private func unrecoverableInvalidCredentialsDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/credentials/invalid",
            "title": "Invalid credentials",
            "status": 401
        ])
    }

    private func unrecoverableNoAccessDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/auth/unrecoverable/saml/no-access",
            "title": "No access",
            "status": 401
        ])
    }

    // MARK: - Problem document fixtures (legacy)

    private func legacyCredentialsInvalidDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeInvalidCredentials,
            "title": "Invalid credentials",
            "status": 401
        ])
    }

    // MARK: - Problem document fixtures (403 forbidden)

    private func licenseExpiredDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/license-expired",
            "title": "License expired",
            "status": 403
        ])
    }

    private func geoRestrictionDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": "http://palaceproject.io/terms/problem/geo-restriction",
            "title": "Outside service area",
            "status": 403
        ])
    }

    private func accountSuspendedDoc() -> TPPProblemDocument {
        TPPProblemDocument.fromDictionary([
            "type": TPPProblemDocument.TypeCredentialsSuspended,
            "title": "Account suspended",
            "status": 403
        ])
    }
}
