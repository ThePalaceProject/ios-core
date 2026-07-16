import XCTest
@testable import TriageBotCore

/// Behavior spec for `HelpEntryPointPolicy` — the pure visibility decision
/// behind every flag-gated Help affordance (book detail, sign-in, audiobook
/// player, settings). Pinning it here (macOS-buildable TriageBotCore) means the
/// AC-14 kill-switch invariant and the audiobook mini-player-collision rule are
/// verified without a sim.
final class HelpEntryPointPolicyTests: XCTestCase {

    // AC-14: when the master kill-switch is off, NO entry point shows Help —
    // regardless of the audiobook-expanded flag. Kills a mutant that drops the
    // `guard triageBotEnabled` short-circuit.
    func testShouldShowHelp_whenFlagOff_isHiddenAtEveryEntryPoint() {
        for entryPoint in HelpEntryPoint.allCases {
            for expanded in [true, false] {
                XCTAssertFalse(
                    HelpEntryPointPolicy.shouldShowHelp(
                        at: entryPoint,
                        triageBotEnabled: false,
                        audiobookPlayerExpanded: expanded
                    ),
                    "\(entryPoint) must be hidden when the flag is off (expanded=\(expanded))"
                )
            }
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

    // The audiobook Help control lives in the FULL player chrome only — showing
    // it on the mini-player would collide with the transport row. So even with
    // the flag on it is hidden until the player is expanded. Kills a mutant that
    // returns `true` (always show) or `false` (never show) for this case.
    func testShouldShowHelp_audiobookPlayer_isVisibleOnlyWhenExpanded() {
        XCTAssertTrue(
            HelpEntryPointPolicy.shouldShowHelp(
                at: .audiobookPlayer,
                triageBotEnabled: true,
                audiobookPlayerExpanded: true
            ),
            "audiobook Help must show in the expanded full player"
        )
        XCTAssertFalse(
            HelpEntryPointPolicy.shouldShowHelp(
                at: .audiobookPlayer,
                triageBotEnabled: true,
                audiobookPlayerExpanded: false
            ),
            "audiobook Help must stay hidden on the mini-player to avoid collision"
        )
    }
}
