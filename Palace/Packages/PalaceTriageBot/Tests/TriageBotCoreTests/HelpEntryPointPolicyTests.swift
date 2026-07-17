import XCTest
@testable import TriageBotCore

/// Behavior spec for `HelpEntryPointPolicy` — the pure visibility decision
/// behind every flag-gated Help affordance (book detail, sign-in, settings).
/// Pinning it here (macOS-buildable TriageBotCore) means the AC-14 kill-switch
/// invariant is verified without a sim.
final class HelpEntryPointPolicyTests: XCTestCase {

    // AC-14: when the master kill-switch is off, NO entry point shows Help.
    // Kills a mutant that drops the `guard triageBotEnabled` short-circuit.
    func testShouldShowHelp_whenFlagOff_isHiddenAtEveryEntryPoint() {
        for entryPoint in HelpEntryPoint.allCases {
            XCTAssertFalse(
                HelpEntryPointPolicy.shouldShowHelp(
                    at: entryPoint,
                    triageBotEnabled: false
                ),
                "\(entryPoint) must be hidden when the flag is off"
            )
        }
    }

    // With the flag on, the non-audiobook entry points are unconditionally
    // visible. Kills a mutant that flips any of these branches to false.
    func testShouldShowHelp_whenFlagOn_staticEntryPointsAreVisible() {
        for entryPoint in [HelpEntryPoint.bookDetail, .signIn] {
            XCTAssertTrue(
                HelpEntryPointPolicy.shouldShowHelp(
                    at: entryPoint,
                    triageBotEnabled: true
                ),
                "\(entryPoint) must be visible when the flag is on"
            )
        }
    }
}
