import XCTest

// KNOWN-BAD fixture for scripts/check-test-name-vs-body.py.
//
// The test name embeds the PascalCase production-class noun
// `TPPReauthenticator` (via the `..._TPPReauthenticatorPath_...` segment), but
// the body never references it — the classic fake-wiring shape from
// .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md. The check MUST flag
// this method.
final class FakeWiringTests: XCTestCase {
    func testRefresh_TPPReauthenticatorPath_invokesRetry() {
        let result = 1 + 1
        XCTAssertEqual(result, 2)
    }
}
