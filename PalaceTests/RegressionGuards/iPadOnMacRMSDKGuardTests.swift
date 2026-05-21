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
        // MISSING-001-OK: compile-time guard — the assertion is "this file
        // compiles", which fails the build if a future deployment-target
        // downgrade removes ProcessInfo.isiOSAppOnMac. No runtime value to
        // assert on (host-dependent).
        let info = ProcessInfo.processInfo
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
