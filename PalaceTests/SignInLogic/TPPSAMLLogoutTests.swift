//
//  TPPSAMLLogoutTests.swift
//  PalaceTests
//
//  TDD tests for PP-3452: iOS adoption of CM SP-initiated SAML Single Logout.
//
//  CM commit 914bff6 (2026-04-07) added `saml_logout_redirect` which:
//   - Requires `Authorization: Bearer <token>` header
//   - Accepts `post_logout_redirect_uri` via RFC 6570 URI template
//     (`{&post_logout_redirect_uri}`)
//   - Redirects back with `logout_status=success|partial` query param
//
//  iOS today: SAML sign-out is local-only — never calls the CM endpoint,
//  leaves the CM bearer token valid and IdP session untouched.
//
//  Contract source: src/palace/manager/integration/patron_auth/saml/provider.py
//  (rel=logout link emitted by CM SAML auth document)
//

import XCTest
@testable import Palace

// MARK: - Fixtures

private enum SAMLSLOFixtures {
    static let authDocumentJSON: String = """
    {
      "id": "https://cm.example.com/TEST/authentication_document",
      "title": "Test SAML Library",
      "authentication": [
        {
          "type": "http://librarysimplified.org/authtype/SAML-2.0",
          "description": "SAML authentication",
          "links": [
            {
              "rel": "authenticate",
              "href": "https://cm.example.com/TEST/saml_authenticate?provider=SAML+2.0+Web+SSO&idp_entity_id=https://idp.example.com/saml",
              "display_names": [{ "language": "en", "value": "SAML IdP" }]
            },
            {
              "rel": "logout",
              "href": "https://cm.example.com/TEST/saml/logout?provider=SAML+2.0+Web+SSO{&post_logout_redirect_uri}",
              "templated": true
            }
          ]
        }
      ]
    }
    """

    static let authDocumentWithoutLogoutLink: String = """
    {
      "id": "https://cm.example.com/OLD/authentication_document",
      "title": "Old SAML Library",
      "authentication": [
        {
          "type": "http://librarysimplified.org/authtype/SAML-2.0",
          "description": "SAML authentication",
          "links": [
            {
              "rel": "authenticate",
              "href": "https://cm.example.com/OLD/saml_authenticate?provider=SAML"
            }
          ]
        }
      ]
    }
    """

    static let basicAuthDocument: String = """
    {
      "id": "https://cm.example.com/BASIC/authentication_document",
      "title": "Basic Library",
      "authentication": [
        {
          "type": "http://opds-spec.org/auth/basic",
          "description": "Basic",
          "inputs": {
            "login": { "keyboard": "Default" },
            "password": { "keyboard": "Default" }
          },
          "labels": { "login": "Barcode", "password": "PIN" }
        }
      ]
    }
    """

    static func authentication(from json: String, matching type: String) throws -> AccountDetails.Authentication {
        let data = json.data(using: .utf8)!
        let doc = try OPDS2AuthenticationDocument.fromData(data)
        guard let raw = doc.authentication?.first(where: { $0.type == type }) else {
            throw NSError(domain: "SAMLSLOFixtures", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No auth block of type \(type)"])
        }
        return AccountDetails.Authentication(auth: raw)
    }
}

// MARK: - Auth-document parsing

final class SAMLLogoutLinkParsingTests: XCTestCase {

    func testSAMLAuth_ParsesLogoutHref_FromAuthDocument() throws {
        let auth = try SAMLSLOFixtures.authentication(
            from: SAMLSLOFixtures.authDocumentJSON,
            matching: "http://librarysimplified.org/authtype/SAML-2.0"
        )
        XCTAssertEqual(auth.authType, .saml, "precondition: auth block must parse as SAML")
        XCTAssertEqual(
            auth.samlLogoutHref,
            "https://cm.example.com/TEST/saml/logout?provider=SAML+2.0+Web+SSO{&post_logout_redirect_uri}",
            "SAML auth document's rel=logout href must be captured verbatim (template preserved)")
    }

    func testSAMLAuth_ParsesLogoutHrefIsTemplated_True() throws {
        let auth = try SAMLSLOFixtures.authentication(
            from: SAMLSLOFixtures.authDocumentJSON,
            matching: "http://librarysimplified.org/authtype/SAML-2.0"
        )
        XCTAssertEqual(auth.samlLogoutHrefIsTemplated, true,
                       "When the CM emits templated=true on the logout link, iOS must record it")
    }

    func testSAMLAuth_WithoutLogoutLink_LeavesHrefNil() throws {
        let auth = try SAMLSLOFixtures.authentication(
            from: SAMLSLOFixtures.authDocumentWithoutLogoutLink,
            matching: "http://librarysimplified.org/authtype/SAML-2.0"
        )
        XCTAssertNil(auth.samlLogoutHref,
                     "CM SAML auth doc without rel=logout must leave samlLogoutHref nil (legacy CM compatibility)")
        XCTAssertNil(auth.samlLogoutHrefIsTemplated)
    }

    func testSAMLLogoutHref_IsNil_ForBasicAuth() throws {
        let auth = try SAMLSLOFixtures.authentication(
            from: SAMLSLOFixtures.basicAuthDocument,
            matching: "http://opds-spec.org/auth/basic"
        )
        XCTAssertEqual(auth.authType, .basic, "precondition: block must parse as basic")
        XCTAssertNil(auth.samlLogoutHref, "Basic auth must never expose samlLogoutHref")
        XCTAssertNil(auth.samlLogoutHrefIsTemplated)
    }

    func testRegression_OIDCLogoutHref_StillPopulated() {
        // Guards against a parser regression: when samlLogoutHref parsing was
        // added, oidcLogoutHref on the OIDC auth path must still populate.
        // Assert BOTH fields are present on the OIDC branch AND that the SAML
        // branch's samlLogoutHref is not bleeding into OIDC's field.
        let libraryMock = TPPLibraryAccountMock()
        let oidc = libraryMock.oidcAuthentication
        let saml = libraryMock.samlAuthentication

        XCTAssertNotNil(oidc.oidcLogoutHref,
                        "OIDC auth must still expose oidcLogoutHref after samlLogoutHref was added")
        XCTAssertNil(oidc.samlLogoutHref,
                     "OIDC auth must NOT expose samlLogoutHref — SAML-specific field")
        XCTAssertNotNil(saml.samlLogoutHref,
                        "SAML auth must expose samlLogoutHref (precondition this test guards against)")
    }
}

// MARK: - URL construction

final class SAMLLogoutURLTests: XCTestCase {

    func testSAMLLogoutURL_ExpandsTemplateWithRedirectURI() throws {
        let href = "https://cm.example.com/TEST/saml/logout?provider=SAML+2.0+Web+SSO{&post_logout_redirect_uri}"
        let expanded = TPPSignInBusinessLogic.expandSAMLLogoutHref(
            href, isTemplated: true,
            postLogoutRedirectURI: "palace-saml-callback://org.thepalaceproject.saml/logout"
        )
        XCTAssertNotNil(expanded, "Template expansion must succeed for valid href + redirect URI")
        XCTAssertTrue(expanded!.absoluteString.contains("post_logout_redirect_uri="),
                      "Expanded URL must contain post_logout_redirect_uri query param")
        XCTAssertFalse(expanded!.absoluteString.contains("{"),
                       "Expanded URL must not contain unresolved template tokens")
    }

    func testSAMLLogoutURL_NonTemplated_UsedAsIs() {
        let href = "https://cm.example.com/TEST/saml/logout?provider=SAML"
        let expanded = TPPSignInBusinessLogic.expandSAMLLogoutHref(
            href, isTemplated: false,
            postLogoutRedirectURI: "palace-saml-callback://org.thepalaceproject.saml/logout"
        )
        XCTAssertEqual(expanded?.absoluteString, href,
                       "Non-templated href must be used verbatim (no mutation, no re-encoding)")
    }

    func testSAMLLogoutURL_InvalidTemplate_ReturnsNil() {
        let bogus = "https://cm.example.com/TEST/saml/logout?{bad_template"
        let expanded = TPPSignInBusinessLogic.expandSAMLLogoutHref(
            bogus, isTemplated: true,
            postLogoutRedirectURI: "palace-saml-callback://org.thepalaceproject.saml/logout"
        )
        XCTAssertNil(expanded,
                     "Malformed template must not produce a URL — caller falls back to local-only cleanup")
    }

    func testSAMLLogoutURL_CallbackSchemeIsPalaceSAML() {
        let uri = TPPSignInBusinessLogic.samlPostLogoutRedirectURI
        XCTAssertTrue(uri.hasPrefix("palace-saml-callback://"),
                      "SAML post-logout redirect URI must use the palace-saml-callback scheme")
        XCTAssertTrue(uri.hasSuffix("/logout"),
                      "Callback path must end with /logout so callback-scheme detection matches")
    }
}

// MARK: - isSAMLLogoutCallbackRedirect detection

final class SAMLLogoutCallbackDetectionTests: XCTestCase {

    func testCallbackSchemeError_DetectedAsSuccess() {
        let failingURL = "palace-saml-callback://org.thepalaceproject.saml/logout?logout_status=success"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnsupportedURL,
            userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL]
        )
        XCTAssertTrue(TPPSignInBusinessLogic.isSAMLLogoutCallbackRedirect(error),
                      "NSURLErrorUnsupportedURL whose failing URL uses palace-saml-callback must be treated as SLO success")
    }

    func testCallbackSchemeError_PartialStatus_AlsoDetected() {
        let failingURL = "palace-saml-callback://org.thepalaceproject.saml/logout?logout_status=partial"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnsupportedURL,
            userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL]
        )
        XCTAssertTrue(TPPSignInBusinessLogic.isSAMLLogoutCallbackRedirect(error),
                      "Callback-scheme redirect with logout_status=partial must still be classified as SLO success (CM handled what it could)")
    }

    func testUnrelatedError_NotDetected() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: nil
        )
        XCTAssertFalse(TPPSignInBusinessLogic.isSAMLLogoutCallbackRedirect(error),
                       "Non-callback errors must not be misclassified as SLO success")
    }

    func testOIDCCallbackScheme_NotSAMLDetected() {
        let failingURL = "palace-oidc-callback://org.thepalaceproject.oidc/logout?logout_status=success"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnsupportedURL,
            userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL]
        )
        XCTAssertFalse(TPPSignInBusinessLogic.isSAMLLogoutCallbackRedirect(error),
                       "OIDC callback-scheme redirects must not be classified as SAML SLO success")
    }
}
