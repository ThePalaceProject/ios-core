import XCTest
@testable import Palace

/// Regression guards for the iPad-on-Mac Adobe RMSDK static-destructor crash
/// (Crashlytics 9a91840677 — 294 events, all iOS_ON_MAC). Adobe's RMSDK uses a
/// static `recursive_mutex` (`dp::DPCriticalSection`) whose destructor faults
/// during `exit()`'s C++ static-destructor pass when the iPad app runs on Apple
/// Silicon Macs.
///
/// The fix (WS-4): on `isiOSAppOnMac` only, terminate via `_exit(0)` to skip the
/// static-destructor pass — `applicationWillTerminate` (Cmd-Q) calls `_exit(0)`
/// last, and `applicationDidEnterBackground` installs an `atexit { _exit(0) }`
/// interceptor (once Adobe DRM has been used this session) for the forced/
/// watchdog path. The `isDRMAvailable` gate (PR #928) is a separate, earlier
/// mitigation that covers only `AdobeDRMService`, not the reader decrypt path.
///
/// These are REAL tests of the gating + idempotency decision logic (the pure
/// helpers `shouldSkipStaticDestructorsOnExit` /
/// `shouldRegisterStaticDestructorBypass` and the `markAdobeDRMUsed` flag). The
/// crash-at-exit itself is Mac-only and not in-process testable — that is
/// validated by the simdrive Mac round-trip (CHECK 2), see
/// `docs/architecture/ws4-mac-validation-runbook.md`.
///
/// See PalaceTests/RegressionGuards/README.md for the full crash narrative.
@MainActor
final class iPadOnMacRMSDKGuardTests: XCTestCase {

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

    // MARK: - "DRM used this session" flag (gates the background install)

    /// The background-entry install fires only when `didUseAdobeDRMThisSession`
    /// is set (by the reader decrypt path). Pin the false→true contract: if the
    /// flag failed to flip on DRM use, the interceptor would never install and
    /// the crash would recur. Reset in setUp keeps it hermetic (set-once flag).
    func testDidUseAdobeDRMThisSession_isFalseUntilMarked_thenTrue() {
        AdobeDRMService.resetAdobeDRMUsedForTesting()
        XCTAssertFalse(AdobeDRMService.didUseAdobeDRMThisSession,
                       "flag must be false before any Adobe DRM use this session")

        AdobeDRMService.markAdobeDRMUsed()
        XCTAssertTrue(AdobeDRMService.didUseAdobeDRMThisSession,
                      "markAdobeDRMUsed() must flip the flag — the gate the background install depends on")

        // Idempotent: a second mark keeps it true (multiple DRM books/decodes).
        AdobeDRMService.markAdobeDRMUsed()
        XCTAssertTrue(AdobeDRMService.didUseAdobeDRMThisSession,
                      "flag stays true across repeated DRM use")
    }
}
