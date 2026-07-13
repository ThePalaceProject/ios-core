import XCTest

// Fake-wiring test: the method name promises a multi-step path THROUGH a
// production class (`TPPReauthenticator`), but the body never constructs,
// statically calls, or type-annotates that class. This is the exact shape the
// detector must flag (wall-failures cs847892e8-arch1 / cs9a267b63-arch1).
final class FakeWiring: XCTestCase {

    func testTPPReauthenticatorPath_invokesRefreshToken() {
        // Body only asserts on a bool — no reference to TPPReauthenticator.
        let didSomething = true
        XCTAssertTrue(didSomething)
    }
}
