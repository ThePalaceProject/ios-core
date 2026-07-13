import XCTest

// Clean wiring test: same multi-step name that embeds `TPPReauthenticator`,
// but the body actually constructs and drives the production class. The
// detector treats the instantiation as wiring evidence and PASSES.
final class CleanWiring: XCTestCase {

    func testTPPReauthenticatorPath_invokesRefreshToken() {
        let sut = TPPReauthenticator()
        sut.refreshToken()
        XCTAssertNotNil(sut)
    }
}
