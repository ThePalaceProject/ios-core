//
//  AccountProfileDocumentTests.swift
//  PalaceTests
//
//  Tests for Account+profileDocument.swift: getProfileDocument.
//  Covers High-priority coverage gap: getProfileDocument.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountProfileDocumentTests: XCTestCase {

    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockImageCache = MockImageCache()
    }

    override func tearDown() {
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - getProfileDocument Tests

    func testGetProfileDocument_WithNilDetails_CompletesWithNil() {
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "urn:uuid:test-profile",
                title: "Test Library"
            ),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)
        XCTAssertNil(account.details)

        let expectation = XCTestExpectation(description: "Completion called")
        account.getProfileDocument { profileDocument in
            XCTAssertNil(profileDocument, "Should return nil when details is nil")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    /// F-007 regression guard: anonymous Palace Bookshelf was hitting
    /// `/patrons/me/` on every cold launch and getting a 401 because
    /// `getProfileDocument` fired the request whenever the auth document
    /// declared a `userProfileUrl`, regardless of whether the current user
    /// had credentials. Discovered by chaos-qa dogfood-3 + dogfood-5;
    /// gated in a single chokepoint at the Account extension. This test
    /// kills the gate-removal mutation on Palace/Accounts/Library/Account+profileDocument.swift.
    func testGetProfileDocument_WhenUserAccountHasNoCredentials_CompletesWithNil_DoesNotFetch() {
        let uuid = "urn:uuid:f007-no-creds-\(UUID().uuidString)"
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: uuid,
                title: "F-007 Test Library"
            ),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)

        let json: [String: Any] = [
            "id": uuid,
            "title": "F-007 Test Library",
            "links": [
                ["rel": "http://librarysimplified.org/terms/rel/user-profile",
                 "href": "https://example.invalid/patrons/me/",
                 "type": "vnd.librarysimplified/user-profile+json"]
            ],
            "authentication": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let authDoc = try! OPDS2AuthenticationDocument.fromData(data)
        account.authenticationDocument = authDoc

        XCTAssertNotNil(account.details?.userProfileUrl,
                        "Test setup precondition: auth doc must declare a user-profile URL.")

        let expectation = XCTestExpectation(description: "Completion called without network")
        let start = Date()
        account.getProfileDocument { profileDocument in
            XCTAssertNil(profileDocument,
                         "Gate must short-circuit when no credentials are stored.")
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                              "Gate must NOT issue a network request — should return synchronously-fast.")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - The gate decision (states x events, asserted directly)
    //
    // These assert the PREDICATE, not `getProfileDocument`, and that is
    // deliberate. `getProfileDocument` reaches `AppContainer.production()`
    // internally, so no test can observe whether the request was actually
    // issued. The F-007 test above claims to "kill the gate-removal mutation";
    // measured on 2026-09-03 it does not — with the entire credentials gate
    // deleted, every test in this file still passed, because
    // `https://example.invalid/` fails DNS fast enough to satisfy both a nil
    // result and a sub-second bound whether or not the request was sent.
    // The decision is therefore lifted into `canAuthenticateProfileRequest`
    // where it can genuinely be falsified, and these four cases are its
    // complete truth table.

    /// Usable credentials: the only cell that may reach the network.
    func testCanAuthenticate_WithValidUnexpiredCredentials_IsTrue() {
        XCTAssertTrue(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: false,
                                                  tokenRefreshWillRepair: false),
            "Usable credentials must reach /patrons/me/ — otherwise profile fetch, "
            + "and with it FCM device registration, is dead for every signed-in patron.")
    }

    /// Expired AND unrepairable: the only cell the expiry arm may block.
    func testCanAuthenticate_WithExpiredTokenThatCannotBeRefreshed_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: true,
                                                  tokenRefreshWillRepair: false),
            "An expired token with no refresh available is a doomed request: it takes a "
            + "401 nothing can repair, and marks the credential stale on the way.")
    }

    /// Expired but repairable — MUST be sent.
    ///
    /// This is the regression the first version of this change introduced. The
    /// reactive 401 path (`TPPNetworkResponder.handleExpiredTokenIfNeeded` →
    /// `refreshTokenAndResume` → `setAuthToken`, which writes `.loggedIn`) repairs
    /// exactly this credential and re-drives the task, so the fetch succeeds today.
    /// Blocking it deletes a working repair — and it can only fire here, since a
    /// non-nil expiry is written by the barcode/PIN→token exchange, the very shape
    /// the refresh can repair.
    func testCanAuthenticate_WithExpiredTokenThatRefreshWillRepair_IsTrue() {
        XCTAssertTrue(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: true,
                                                  tokenRefreshWillRepair: true),
            "An expired token the reactive 401 refresh can repair MUST still be sent — "
            + "blocking it removes a repair that works today and strands the fetch.")
    }

    /// The original F-007 case, now actually asserted.
    func testCanAuthenticate_WithNoCredentials_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: false,
                                                  tokenHasExpired: false,
                                                  tokenRefreshWillRepair: false),
            "Anonymous libraries advertise a userProfileUrl but store no credentials; "
            + "firing anyway is the /patrons/me/ 401 storm of PP-4164 / F-007.")
    }

    /// Absence of credentials is decisive over BOTH other inputs.
    /// Pinned so the predicate cannot be rewritten to ignore `hasCredentials`.
    func testCanAuthenticate_WithNoCredentials_IsFalseRegardlessOfTokenState() {
        for expired in [true, false] {
            for repairable in [true, false] {
                XCTAssertFalse(
                    Account.canAuthenticateProfileRequest(hasCredentials: false,
                                                          tokenHasExpired: expired,
                                                          tokenRefreshWillRepair: repairable),
                    "No credentials must be decisive (expired: \(expired), repairable: \(repairable))")
            }
        }
    }

    /// The 8th cell: expired + repairable + NO credentials.
    /// Pinned so `hasCredentials` cannot be dropped from the predicate — with
    /// only 7 cells asserted, `!tokenHasExpired || tokenRefreshWillRepair` alone
    /// would pass everything else.
    func testCanAuthenticate_NoCredentialsExpiredAndRepairable_IsFalse() {
        XCTAssertFalse(
            Account.canAuthenticateProfileRequest(hasCredentials: false,
                                                  tokenHasExpired: true,
                                                  tokenRefreshWillRepair: true),
            "There is nothing to refresh without credentials — absence is decisive over repairability")
    }

    /// The cell that was missing through three rounds: credentials present,
    /// token NOT expired, refresh would repair. Reachable via the
    /// `isOAuthAndNeedsRefresh` arm. Kills the `||` -> `!=` mutant.
    func testCanAuthenticate_credentialsUnexpiredAndRepairable_IsTrue() {
        XCTAssertTrue(
            Account.canAuthenticateProfileRequest(hasCredentials: true,
                                                  tokenHasExpired: false,
                                                  tokenRefreshWillRepair: true),
            "An unexpired credential must reach the network regardless of repairability — "
            + "this is the cell I twice claimed to have added and twice added a duplicate of")
    }

    // MARK: - The gate is REACHED (not just correct)

    // SoD review defeated the gate additively: inserting
    // `if userAccount.authTokenHasExpired { completion(nil); return }` ABOVE it
    // re-introduced the round-1 regression with all 42 tests green. Source-text
    // lints are monotone — they catch deletion, never insertion. Only observing
    // whether the request was ISSUED catches it, which is what these do.

    /// Builds an account whose auth document declares a user-profile URL.
    private func accountWithProfileURL(uuid: String) -> Account {
        let publication = OPDS2Publication(
            links: [],
            metadata: OPDS2Publication.Metadata(
                updated: Date(), description: nil, id: uuid, title: "Seam Test Library"),
            images: nil
        )
        let account = Account(publication: publication, imageCache: mockImageCache)
        let json: [String: Any] = [
            "id": uuid,
            "title": "Seam Test Library",
            "links": [
                ["rel": "http://librarysimplified.org/terms/rel/user-profile",
                 "href": "https://example.invalid/patrons/me/",
                 "type": "vnd.librarysimplified/user-profile+json"]
            ],
            "authentication": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        account.authenticationDocument = try! OPDS2AuthenticationDocument.fromData(data)
        return account
    }

    /// The gate must be REACHED, and when it blocks, no request may be issued.
    ///
    /// This is what the old F-007 guard only claimed to do. It asserted a nil
    /// document and sub-second timing against `example.invalid`, both of which
    /// hold whether or not the request goes out — measured, it survived deleting
    /// the entire gate. Observing the request directly is the difference.
    func testGetProfileDocument_withoutCredentials_issuesNoRequest() {
        let account = accountWithProfileURL(uuid: "urn:uuid:seam-no-creds-\(UUID().uuidString)")
        XCTAssertNotNil(account.details?.userProfileUrl,
                        "Precondition: the auth doc must declare a profile URL, or this proves nothing")

        var issued: [URLRequest] = []
        var completions: [UserProfileDocument?] = []

        // No expectation, and deliberately no deadline. The blocked path is
        // `completion(nil); return` on the calling thread — no Task, no network,
        // no main-queue hop — so the call has already settled by the time it
        // returns. A deadline-poll wait here would be a fixed wall-clock bound on
        // work that is not async at all, which is what STARVE-001 exists to
        // stop: it starves under parallel sim clones and fails all three CI
        // retries. Asserting after the synchronous return is both honest and
        // strictly stronger — if this path ever becomes asynchronous, this
        // fails immediately instead of passing on a generous timeout.
        account.getProfileDocument(performRequest: { request, _ in
            issued.append(request)
        }, completion: { document in
            completions.append(document)
        })

        XCTAssertEqual(completions.count, 1,
                       "The blocked path must complete synchronously — one call, before this line runs")
        XCTAssertNil(completions.first ?? nil, "A blocked request yields no profile document")
        XCTAssertTrue(issued.isEmpty,
                      "With no credentials the gate must block BEFORE the network. A request here is the "
                      + "/patrons/me/ 401 storm of PP-4164 / F-007 — and it is observable now, where the "
                      + "old timing-based guard could not see it.")
    }

    // MARK: - isTokenRefreshRequired: the gate's repairability input

    // SoD review found my first attempt at these was one test written three
    // times: all three passed `authDefinition: nil`, and the helper's first line
    // is `guard let authDefinition else { return false }` — so all three hit the
    // same early return, production always passes non-nil, and NO test reached a
    // `true` return. A reviewer inverted the token branch AND forced the
    // non-token branch to `return true` with the suite still green. These drive
    // a real auth definition.

    /// Builds a token-auth definition the way the contract tests do.
    private func tokenAuthDefinition(tokenURL: String?) -> AccountDetails.Authentication {
        // `tokenURL` is read from a LINKS array (`rel == "authenticate"`), not a
        // top-level key — my first fixture used the wrong shape and the guard
        // below caught it rather than letting the test pass through the helper's
        // early return.
        let links = tokenURL.map { """
        , "links": [{ "rel": "authenticate", "href": "\($0)" }]
        """ } ?? ""
        let json = """
        {
          "type": "http://thepalaceproject.org/authtype/basic-token",
          "description": "Token auth"\(links)
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    /// THE case the whole narrowing rests on: an expired token that CAN be
    /// refreshed must report repairable, so the gate lets the request through
    /// and the reactive 401 repair runs. Nothing previously reached this.
    func testIsTokenRefreshRequired_expiredTokenWithTokenURLAndBarcodePIN_isTrue() {
        let auth = tokenAuthDefinition(tokenURL: "https://example.invalid/token")
        guard auth.isToken, auth.tokenURL != nil else {
            return XCTFail("Fixture did not produce a token auth definition with a tokenURL — "
                           + "the test would otherwise pass through the early return and prove nothing")
        }

        XCTAssertTrue(
            UserAccountAuthHelper.isTokenRefreshRequired(
                authDefinition: auth,
                credentials: .token(authToken: "t", barcode: "b", pin: "p",
                                    expirationDate: Date(timeIntervalSinceNow: -60)),
                username: "b",
                pin: "p"),
            "An expired token with a tokenURL, barcode and PIN IS repairable — this is the input that "
            + "keeps the gate from deleting the working reactive refresh")
    }

    /// Same credential, no tokenURL: not repairable, so the gate legitimately blocks.
    func testIsTokenRefreshRequired_expiredTokenWithoutTokenURL_isFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenRefreshRequired(
                authDefinition: tokenAuthDefinition(tokenURL: nil),
                credentials: .token(authToken: "t", barcode: "b", pin: "p",
                                    expirationDate: Date(timeIntervalSinceNow: -60)),
                username: "b",
                pin: "p"),
            "With no tokenURL there is nothing to refresh against — the residual case where blocking is right")
    }

    /// An UNEXPIRED token needs no refresh — pins the expiry direction.
    func testIsTokenRefreshRequired_unexpiredToken_isFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenRefreshRequired(
                authDefinition: tokenAuthDefinition(tokenURL: "https://example.invalid/token"),
                credentials: .token(authToken: "t", barcode: "b", pin: "p",
                                    expirationDate: Date(timeIntervalSinceNow: 3600)),
                username: "b",
                pin: "p"),
            "A live token does not need refreshing")
    }

    /// Missing barcode/PIN cannot drive a refresh even with a tokenURL.
    func testIsTokenRefreshRequired_expiredTokenWithoutBarcodeOrPIN_isFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenRefreshRequired(
                authDefinition: tokenAuthDefinition(tokenURL: "https://example.invalid/token"),
                credentials: .token(authToken: "t", barcode: nil, pin: nil,
                                    expirationDate: Date(timeIntervalSinceNow: -60)),
                username: nil,
                pin: nil),
            "The refresh exchange needs a barcode and PIN; without them it cannot repair")
    }

    func testIsTokenRefreshRequired_noAuthDefinition_isFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenRefreshRequired(
                authDefinition: nil, credentials: nil, username: nil, pin: nil),
            "No auth definition means no known refresh mechanism")
    }

    // MARK: - isTokenExpired: the claims the gate relies on, pinned

    // The gate's docstring asserts that basic-auth libraries and OIDC are
    // unaffected because `isTokenExpired` is false for them. That was prose.
    // These drive the real helper so the claim cannot rot silently.

    func testIsTokenExpired_ForBarcodeAndPINCredential_IsFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenExpired(
                credentials: .barcodeAndPin(barcode: "1234", pin: "0000")),
            "Basic-auth libraries have no token to expire — the expiry arm must never fire for them.")
    }

    func testIsTokenExpired_ForTokenWithNoExpiryDate_IsFalse() {
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenExpired(
                credentials: .token(authToken: "t", barcode: "1234", pin: "0000", expirationDate: nil)),
            "A token with no expiry does not expire. OIDC stores nil here, so the arm cannot fire on OIDC.")
    }

    func testIsTokenExpired_ForNoCredentials_IsFalse() {
        XCTAssertFalse(UserAccountAuthHelper.isTokenExpired(credentials: nil),
                       "Absent credentials are not an expired token — that is the hasCredentials arm's job.")
    }

    func testIsTokenExpired_ForPastExpiry_IsTrue_AndFutureIsFalse() {
        let past = Date(timeIntervalSinceNow: -60)
        let future = Date(timeIntervalSinceNow: 3600)
        XCTAssertTrue(
            UserAccountAuthHelper.isTokenExpired(
                credentials: .token(authToken: "t", barcode: "b", pin: "p", expirationDate: past)),
            "A token whose expiry has passed is expired")
        XCTAssertFalse(
            UserAccountAuthHelper.isTokenExpired(
                credentials: .token(authToken: "t", barcode: "b", pin: "p", expirationDate: future)),
            "A token expiring in the future is not expired — pins the comparison direction")
    }
}
