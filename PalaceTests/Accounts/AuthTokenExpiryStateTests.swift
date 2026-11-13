//
//  AuthTokenExpiryStateTests.swift
//
//  PP-5318. `setAuthToken` flipped `authState` to `.loggedIn` unconditionally,
//  so writing a token always claimed a healthy session, even one already
//  expired. That made the lapsed-token state unreachable and let a refresh
//  returning a dead token report itself signed in.
//
//  The nil-expiry callers OIDCReauth and TokenRefreshInterceptor are pinned
//  here too: keying the fix on "has an expiration date" rather than "is
//  expired" would stop clearing their stale flag, which is the re-prompt
//  regression the method's own comment guards.
//

import XCTest
@testable import Palace

final class AuthTokenExpiryStateTests: XCTestCase {

    private var account: TPPUserAccount!

    override func setUp() {
        super.setUp()
        account = TPPUserAccountTestFactory.makeIsolated()
    }

    override func tearDown() {
        account?.removeAll()
        account = nil
        super.tearDown()
    }

    // MARK: - An already-expired token must not claim a healthy session

    /// The defect PP-5318 exists for. A tester marks credentials stale and
    /// writes an expired token; the write must not quietly undo the marking.
    func testWritingAnExpiredToken_leavesCredentialsStale() {
        account.setAuthToken("good", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.markCredentialsStale()
        XCTAssertEqual(account.authState, .credentialsStale, "arrange: stale before the write")

        account.setAuthToken("expired-token", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))

        XCTAssertEqual(
            account.authState, .credentialsStale,
            "writing an already-expired token must not re-mark the account signed in; "
            + "that is what made the lapsed-token state unreachable"
        )
    }

    /// The expired token still has to be STORED, or the expiry paths have
    /// nothing to read and the state is unreachable for a different reason.
    func testWritingAnExpiredToken_stillStoresItAndReportsExpiry() {
        account.setAuthToken("expired-token", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))

        XCTAssertEqual(account.authToken, "expired-token",
                       "the token must persist so the expiry branch can read it")
        XCTAssertTrue(account.authTokenHasExpired,
                      "the stored token must report itself expired")
    }

    /// Without this, the fix could be "never flip to .loggedIn", which would
    /// break sign-in rather than the debug tool.
    func testWritingAFutureDatedToken_marksSignedIn() {
        account.setAuthToken("fresh", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))

        XCTAssertEqual(account.authState, .loggedIn)
        XCTAssertFalse(account.authTokenHasExpired)
    }

    /// A future-dated token must also CLEAR a stale flag, which is the
    /// behaviour `setAuthToken`'s comment exists to protect: silent re-auth
    /// must not leave `.credentialsStale` persisted across launches.
    func testWritingAFutureDatedToken_clearsAStaleFlag() {
        account.setAuthToken("good", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.markCredentialsStale()
        XCTAssertEqual(account.authState, .credentialsStale, "arrange")

        account.setAuthToken("refreshed", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))

        XCTAssertEqual(account.authState, .loggedIn,
                       "a usable token must clear the stale flag, or re-auth "
                       + "re-prompts on the next cold start")
    }

    // MARK: - The nil-expiry callers found by census

    /// `OIDCReauth` and `TokenRefreshInterceptor` both pass
    /// `expirationDate: nil`, and `isTokenExpired` treats nil as "does not
    /// expire". A fix keyed on the presence of a date rather than on expiry
    /// would stop clearing the stale flag for both of them.
    func testWritingATokenWithNoExpiry_marksSignedIn() {
        account.setAuthToken("no-expiry", barcode: "b", pin: "p",
                             expirationDate: nil)

        XCTAssertEqual(account.authState, .loggedIn)
        XCTAssertFalse(account.authTokenHasExpired,
                       "no expiration means the token does not expire")
    }

    func testWritingATokenWithNoExpiry_clearsAStaleFlag() {
        account.setAuthToken("good", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.markCredentialsStale()
        XCTAssertEqual(account.authState, .credentialsStale, "arrange")

        account.setAuthToken("no-expiry", barcode: "b", pin: "p",
                             expirationDate: nil)

        XCTAssertEqual(account.authState, .loggedIn,
                       "the two nil-expiry re-auth callers must still clear the flag")
    }
    // MARK: - markLoggedIn must not undo the setAuthToken guard

    /// The second half of this ticket's scope. `markLoggedIn()` was a bare
    /// `setAuthState(.loggedIn)`, and both production writers call it
    /// immediately after `setAuthToken` — `TPPNetworkExecutor.executeTokenRefresh`
    /// and `TPPSignInBusinessLogic.updateUserAccount`. So the guard above was
    /// overridden one line later and an expired token still claimed a session.
    func testMarkingLoggedInAfterAnExpiredTokenWrite_leavesCredentialsStale() {
        account.setAuthToken("good", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.markCredentialsStale()
        XCTAssertEqual(account.authState, .credentialsStale, "arrange: stale before the refresh")

        account.setAuthToken("expired-token", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: -3600))
        account.markLoggedIn()

        XCTAssertEqual(
            account.authState, .credentialsStale,
            "a refresh that returns a dead token must not clear the stale flag"
        )
    }

    /// Barcode/PIN credentials are not a token, so `isTokenExpired` is false
    /// for them: the basic-auth sign-in path must still mark signed in.
    func testMarkingLoggedInWithBarcodeAndPin_marksSignedIn() {
        account.setBarcode("12345", PIN: "0000")
        account.setAuthState(.loggedOut)

        account.markLoggedIn()

        XCTAssertEqual(account.authState, .loggedIn,
                       "basic auth stores no token and must be unaffected")
    }

    /// The two nil-expiry callers found by census, at the markLoggedIn seam.
    func testMarkingLoggedInWithANonExpiringToken_marksSignedIn() {
        account.setAuthToken("no-expiry", barcode: "b", pin: "p",
                             expirationDate: nil)
        account.setAuthState(.credentialsStale)

        account.markLoggedIn()

        XCTAssertEqual(account.authState, .loggedIn,
                       "no expiration means the token does not expire")
    }

    /// Pins the boundary at expired, not near-expiry. `isTokenNearExpiry`
    /// is true 5 minutes out and would be an easy substitution here; a token
    /// with a minute left is still usable, and proactive refresh is
    /// `TokenRefreshInterceptor`'s job, not this method's.
    func testMarkingLoggedInWithATokenAboutToExpire_marksSignedIn() {
        account.setAuthToken("nearly-stale", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 60))
        account.setAuthState(.credentialsStale)

        account.markLoggedIn()

        XCTAssertEqual(account.authState, .loggedIn,
                       "a token that has not expired yet is still usable")
    }

    func testMarkingLoggedInWithAFutureDatedToken_marksSignedIn() {
        account.setAuthToken("fresh", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.setAuthState(.credentialsStale)

        account.markLoggedIn()

        XCTAssertEqual(account.authState, .loggedIn)
    }

    // MARK: - The production refresh path, end to end

    /// Drives the real `executeTokenRefresh` against a stubbed /token that
    /// answers with a negative `expires_in`, so `TokenResponse.expirationDate`
    /// is already in the past. A real account is injected rather than a mock,
    /// because the behaviour under test lives in `TPPUserAccount`.
    func testTokenRefreshReturningAnExpiredToken_doesNotClearTheStaleFlag() async {
        account.setAuthToken("good", barcode: "b", pin: "p",
                             expirationDate: Date(timeIntervalSinceNow: 3600))
        account.markCredentialsStale()
        XCTAssertEqual(account.authState, .credentialsStale, "arrange: a 401 marked it stale")

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.register { request in
            guard request.url?.absoluteString.contains("token") == true else { return nil }
            let json = """
            {"access_token":"already-expired","token_type":"Bearer","expires_in":-3600}
            """.data(using: .utf8)!
            return HTTPStubURLProtocol.StubbedResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: json
            )
        }
        defer { HTTPStubURLProtocol.reset() }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        let accounts = TPPLibraryAccountMock()
        let injected = account!
        accounts.userAccountResolver = { _ in injected }
        let executor = TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: accounts,
            delegateQueue: nil
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            executor.executeTokenRefresh(
                username: "b",
                password: "p",
                tokenURL: URL(string: "https://example.com/token")!,
                accountId: "urn:uuid:expiry-test"
            ) { _ in continuation.resume() }
        }

        XCTAssertEqual(account.authToken, "already-expired",
                       "the refreshed token is still stored")
        XCTAssertTrue(account.authTokenHasExpired,
                      "arrange check: the stubbed token is already expired")
        XCTAssertEqual(
            account.authState, .credentialsStale,
            "the refresh must not report a healthy session for a dead token"
        )
    }
}
