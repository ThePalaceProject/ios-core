import XCTest

// KNOWN-GOOD fixture for scripts/check-test-name-vs-body.py.
//
// Same multi-step test name as the bad fixture (it embeds `TPPReauthenticator`
// via the `..._TPPReauthenticatorPath_...` segment), but the body actually
// instantiates and drives `TPPReauthenticator`, so the wiring claim is honest.
// The check MUST pass this method.
final class RealWiringTests: XCTestCase {
    func testRefresh_TPPReauthenticatorPath_invokesRetry() {
        let reauth = TPPReauthenticator()
        reauth.refresh()
        XCTAssertTrue(true)
    }
}
