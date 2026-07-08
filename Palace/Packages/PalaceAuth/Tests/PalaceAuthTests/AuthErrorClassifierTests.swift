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

    // MARK: - Rule 4b: foreign-host 401 -> .ok (PR #1018 cross-host regression fix)

    /// CRITICAL — the device-reproduced Icarus regression. An Icarus
    /// (`minotaur.dev.palaceproject.io`) account is current; a 401 arrives
    /// from `gorgon.staging.palaceproject.io` (A1QA playtimes upload). The
    /// hosts share base domain `palaceproject.io`, so the existing Rule 4
    /// (base-domain cross-domain) does NOT fire. Rule 4b MUST fire and
    /// short-circuit to `.ok` — otherwise the responder dispatches a
    /// modal for the wrong account every minute.
    func testClassify_401FromForeignHost_withCurrentAccountHostsProvider_returnsOk() {
        let hostScopedClassifier = AuthErrorClassifier(
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        let foreignHostURL = URL(string: "https://gorgon.staging.palaceproject.io/a1qa-test/playtimes/14/URI/urn:uuid:2265844e-0")!
        let outcome = hostScopedClassifier.classify(
            response: httpResponse(url: foreignHostURL, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: foreignHostURL
        )
        XCTAssertEqual(outcome, .ok,
                       "401 from a host outside the current account's auth surface MUST classify as .ok — would otherwise mis-attribute a foreign library's 401 to the current OIDC/SAML account and pop a sign-in modal for the wrong account.")
    }

    /// Inverse of the foreign-host test: when the 401 is from a host THAT
    /// IS in the current account's auth-surface set, Rule 4b must NOT
    /// fire — the classifier falls through to legacy 401 handling and
    /// returns `.reauthRequired`. Without this we'd block legitimate
    /// session-expired 401s for the current account.
    func testClassify_401FromCurrentAccountHost_withCurrentAccountHostsProvider_returnsReauthRequired() {
        let hostScopedClassifier = AuthErrorClassifier(
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        let homeHostURL = URL(string: "https://minotaur.dev.palaceproject.io/icarus-test-library/borrow/123")!
        let outcome = hostScopedClassifier.classify(
            response: httpResponse(url: homeHostURL, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: homeHostURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401),
                       "401 from a host IN the current account's auth surface MUST NOT be short-circuited by Rule 4b — legacy 401 handling applies (bare-401 → .reauthRequired(.unknown401)). A regression that always returns .ok would silently swallow real session-expired 401s.")
    }

    /// Backward-compat: a classifier constructed without a host provider
    /// must behave EXACTLY as it did pre-fix — Rule 4b is dormant, the
    /// 401 falls through to legacy handling. Without this, the fix would
    /// change the behavior of every existing test that uses the
    /// no-arg `AuthErrorClassifier()` initializer.
    func testClassify_401WithDefaultProvider_fallsBackToLegacyBehavior() {
        let outcome = classifier.classify(
            response: httpResponse(url: URL(string: "https://gorgon.staging.palaceproject.io/x")!, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: URL(string: "https://gorgon.staging.palaceproject.io/x")!
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401),
                       "Default `{ nil }` provider MUST disable Rule 4b — legacy 401 behavior preserved for all callers that don't opt in. Regression here would change behavior for every existing classifier call site.")
    }

    /// Cold-launch trade-off: while the auth document is loading, the
    /// account's `authSurfaceHosts` is empty. Treating an empty set as
    /// "block everything not in the (empty) set" would falsely-block
    /// real 401s during cold launch. Empty MUST fall back to legacy
    /// behavior — same as nil provider.
    func testClassify_401WithEmptyCurrentAccountHostsSet_fallsBackToLegacyBehavior() {
        let coldLaunchClassifier = AuthErrorClassifier(
            currentAccountHostsProvider: { Set<String>() }
        )
        let url = URL(string: "https://gorgon.staging.palaceproject.io/playtimes/14")!
        let outcome = coldLaunchClassifier.classify(
            response: httpResponse(url: url, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: url
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401),
                       "Empty hosts set must be treated as 'no info, don't scope' (legacy fallback) — false-blocking a real 401 during cold launch is worse than the transient legacy-behavior window.")
    }

    /// Belt-and-braces case-insensitive comparison. `URL.host` returns
    /// whatever case the URL string used; `Account.authSurfaceHosts`
    /// lowercases at the producer, so the classifier lowercases at the
    /// consumer too. A regression that drops either side would
    /// false-block a 401 whose URL happens to come back from a
    /// proxy-rewritten capitalized host.
    func testClassify_401FromCurrentAccountHost_caseInsensitiveMatch_returnsReauthRequired() {
        let hostScopedClassifier = AuthErrorClassifier(
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        let mixedCaseURL = URL(string: "https://Minotaur.Dev.PalaceProject.io/icarus-test-library/borrow/123")!
        let outcome = hostScopedClassifier.classify(
            response: httpResponse(url: mixedCaseURL, status: 401),
            problemDocument: nil,
            body: nil,
            originalRequestURL: mixedCaseURL
        )
        XCTAssertEqual(outcome, .reauthRequired(reason: .unknown401),
                       "Case-insensitive host matching: 'Minotaur.Dev.PalaceProject.io' (mixed) must match 'minotaur.dev.palaceproject.io' (lowercase set entry). A regression here would treat the request as foreign-host and silently drop a real session-expired 401.")
    }

    /// Rule 4 + Rule 4b ordering pin. When BOTH would yield `.ok`, Rule 4
    /// must fire first. The test drives a request where the response
    /// host crosses a true base-domain boundary AND the request host is
    /// outside the current-account set. Both rules would return `.ok`;
    /// the test passing on this input doesn't prove ORDER per se, but
    /// the assertion plus the no-provider variant of the same scenario
    /// (Rule 4 alone) pins that Rule 4 isn't being silently bypassed.
    func testClassify_401_baseDomainCrossOrigin_andForeignHost_returnsOkViaRule4() {
        let hostScopedClassifier = AuthErrorClassifier(
            currentAccountHostsProvider: { Set(["minotaur.dev.palaceproject.io"]) }
        )
        let originalURL = URL(string: "https://gorgon.staging.palaceproject.io/some/loans/path")!
        let crossDomainResponseURL = URL(string: "https://library.biblioboard.com/blob/xyz")!
        let response = httpResponse(url: crossDomainResponseURL, status: 401)

        let outcome = hostScopedClassifier.classify(
            response: response,
            problemDocument: nil,
            body: nil,
            originalRequestURL: originalURL
        )
        XCTAssertEqual(outcome, .ok,
                       "Both Rule 4 (true cross-base-domain CDN) and Rule 4b (foreign host) would yield .ok; Rule 4 must fire first because it's checked first. A future refactor that swaps the order should still produce .ok (both apply), but if Rule 4 is removed entirely, this test pins that the foreign-host check at least covers the case.")

        // Pair with the no-provider variant — proves Rule 4 alone still
        // catches the true cross-base-domain CDN even when Rule 4b is
        // dormant. If a regression removed Rule 4 but kept Rule 4b, this
        // pair would still pass because Rule 4b matches the request host
        // not being in the (nil) set. Pin both: with the default
        // `{ nil }` provider, Rule 4 must still fire on this same input.
        let outcomeNoProvider = classifier.classify(
            response: response,
            problemDocument: nil,
            body: nil,
            originalRequestURL: originalURL
        )
        XCTAssertEqual(outcomeNoProvider, .ok,
                       "Rule 4 (base-domain cross-domain) must still fire on its own with the default `{ nil }` provider — this is the pre-existing CDN guard and removing it would break biblioboard.com flows.")
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
