import XCTest
@testable import Palace

/// Regression guards for the iPad-on-Mac Adobe RMSDK static-destructor crash
/// (294 events on Crashlytics post-3.0.0). Adobe's RMSDK uses a static
/// `recursive_mutex` whose destructor fails the lock when the iPad app
/// runs on Apple Silicon Macs (Mac Catalyst-style host).
///
/// The fix surface — PR #928 (`fix/adobe-drm-ipad-on-mac`) —
/// short-circuits Adobe DRM initialization when
/// `ProcessInfo.processInfo.isiOSAppOnMac == true`.
///
/// **Status: PR #928 is open against develop and not yet merged.** This
/// file holds **placeholder** tests that pass today but assert what the
/// fix is *supposed* to guarantee. Once #928 lands, expand the assertions
/// per the README's "Adding a new regression guard" steps.
///
/// See PalaceTests/RegressionGuards/README.md for the full crash narrative.
final class iPadOnMacRMSDKGuardTests: XCTestCase {

    // MARK: - Placeholder: documents expected post-merge behavior

    func testProcessInfoExposes_isiOSAppOnMac_OnSupportedSDKs() {
        // The fix relies on `ProcessInfo.processInfo.isiOSAppOnMac`,
        // available on iOS 14+ / Mac Catalyst 14+. Palace deploys to
        // iOS 16+ so this property is always available. If a future
        // deployment-target downgrade removes it, this test will fail
        // to compile — which is the desired signal.
        let info = ProcessInfo.processInfo
        // The property exists at compile time; runtime value depends on host.
        // We're not asserting the value (it's environment-dependent on the
        // test runner) — we're asserting the API exists and is reachable.
        _ = info.isiOSAppOnMac
    }

    // TODO(#928 merged): replace this body with assertions on
    // AdobeDRMHandler.shouldEnable when called with isiOSAppOnMac=true vs false.
    // Example shape (post-merge):
    //
    //   func testAdobeDRMHandler_OnIPadOnMac_ShouldEnableReturnsFalse() {
    //       let handler = AdobeDRMHandler.test_makeForIsiOSAppOnMac(true)
    //       XCTAssertFalse(handler.shouldEnable,
    //           "regression — Adobe DRM must remain disabled on iPad-on-Mac")
    //   }
}
