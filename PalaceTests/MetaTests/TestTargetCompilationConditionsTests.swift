//
//  `#if` in a test file is evaluated against the test target's
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS, not the app's. When a flag is missing the
//  guarded bodies compile to their `#else` (usually `throw XCTSkip`), which
//  reports as a pass; 27 blocks across 16 files stopped running that way. This
//  guard is written in the same `#if` form, so it only passes when the condition
//  is really set.
//

import XCTest

final class TestTargetCompilationConditionsTests: XCTestCase {

    /// Fails closed if `FEATURE_DRM_CONNECTOR` is ever dropped from the
    /// PalaceTests target again.
    ///
    /// Note the shape: the failure lives in the `#else`, so a regression
    /// produces a NAMED failing test rather than a silent skip. Asserting
    /// something in the `#if` branch instead would regress to exactly the
    /// invisible behaviour this exists to prevent.
    func test_palaceTestsTarget_definesFeatureDRMConnector() {
        #if FEATURE_DRM_CONNECTOR
        // Intentionally empty: reaching here IS the assertion.
        #else
        XCTFail(
            "PalaceTests is compiled without FEATURE_DRM_CONNECTOR. Every "
            + "`#if FEATURE_DRM_CONNECTOR` block in a test file is now taking "
            + "its `#else` branch — typically `throw XCTSkip` — so Adobe DRM "
            + "coverage is silently absent and reporting green. Restore it in "
            + "SWIFT_ACTIVE_COMPILATION_CONDITIONS for the PalaceTests target "
            + "(Debug and Release)."
        )
        #endif
    }

    /// The sibling flags the target already carried. Included so a merge that
    /// rewrites the whole setting — the realistic regression, since this is a
    /// single space-separated string — cannot restore one flag and drop
    /// another without a named failure.
    func test_palaceTestsTarget_retainsItsOtherFeatureFlags() {
        #if !LCP
        XCTFail("PalaceTests lost LCP — LCP-guarded test bodies are now skipping silently.")
        #endif
        #if !FEATURE_OVERDRIVE
        XCTFail("PalaceTests lost FEATURE_OVERDRIVE — OverDrive-guarded test bodies are now skipping silently.")
        #endif
    }
}
