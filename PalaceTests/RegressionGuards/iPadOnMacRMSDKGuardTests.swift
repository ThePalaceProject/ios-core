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

    // MARK: - WS-4: _exit(0) static-destructor bypass

    // The `isDRMAvailable` gate stops *our* RMSDK init but cannot stop the
    // C++ runtime from constructing/destructing RMSDK's load-time static
    // recursive_mutex — so the crash persists at exit() teardown. OPTION 1
    // skips the destructor pass entirely via _exit(0) on iPad-on-Mac. These
    // guards pin the decision logic so the gating can't silently regress to
    // affect iOS devices, and so the one-shot registration stays idempotent.

    func testShouldSkipStaticDestructorsOnExit_OnIPadOnMac_ReturnsTrue() {
        XCTAssertTrue(
            shouldSkipStaticDestructorsOnExit(isiOSAppOnMac: true),
            "iPad-on-Mac must bypass C++ static destructors at exit — Adobe RMSDK's static recursive_mutex destructor faults there"
        )
    }

    func testShouldSkipStaticDestructorsOnExit_OnIOSDevice_ReturnsFalse() {
        XCTAssertFalse(
            shouldSkipStaticDestructorsOnExit(isiOSAppOnMac: false),
            "regression — real iOS devices must NEVER skip normal exit cleanup; _exit there would bypass legitimate static teardown"
        )
    }

    // NOTE: no `#if FEATURE_DRM_CONNECTOR` guard here. AdobeDRMService is
    // compiled into the Palace module under that condition, but the PalaceTests
    // target does NOT define FEATURE_DRM_CONNECTOR as a Swift active-compilation
    // condition — guarding the test source would silently exclude these cases
    // (they'd never run). The symbol is reachable via `@testable import Palace`
    // because it exists in the imported module, independent of the test
    // target's own conditions.
    func testShouldRegisterStaticDestructorBypass_OnIPadOnMac_NotYetRegistered_Registers() {
        XCTAssertTrue(
            AdobeDRMService.shouldRegisterStaticDestructorBypass(isiOSAppOnMac: true, alreadyRegistered: false),
            "first call on iPad-on-Mac must install the atexit interceptor"
        )
    }

    func testShouldRegisterStaticDestructorBypass_OnIPadOnMac_AlreadyRegistered_DoesNotReRegister() {
        XCTAssertFalse(
            AdobeDRMService.shouldRegisterStaticDestructorBypass(isiOSAppOnMac: true, alreadyRegistered: true),
            "idempotency — the atexit interceptor must be installed at most once"
        )
    }

    func testShouldRegisterStaticDestructorBypass_OnIOSDevice_NeverRegisters() {
        XCTAssertFalse(
            AdobeDRMService.shouldRegisterStaticDestructorBypass(isiOSAppOnMac: false, alreadyRegistered: false),
            "regression — must never install a _exit interceptor on real iOS devices"
        )
        XCTAssertFalse(
            AdobeDRMService.shouldRegisterStaticDestructorBypass(isiOSAppOnMac: false, alreadyRegistered: true),
            "device path stays a no-op regardless of prior registration state"
        )
    }
}
