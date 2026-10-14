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
}
