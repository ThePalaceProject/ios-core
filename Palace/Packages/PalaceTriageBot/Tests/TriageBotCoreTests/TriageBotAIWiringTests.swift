import XCTest
@testable import TriageBotCore

/// Table test for the AI-fallback wiring invariant. The whole point of the AI
/// fallback being "inert by default" is that it wires ONLY when the flag is on
/// AND a key is present — so all four flag×key combinations are pinned here.
final class TriageBotAIWiringTests: XCTestCase {

    func testAIWiring_requiresBothFlagAndKey() {
        // Neither → off.
        XCTAssertFalse(TriageBotAIWiring.aiWiring(flagEnabled: false, keyPresent: false))
        // Flag on but no key → off (the demo-machine / TestFlight-without-key case).
        XCTAssertFalse(TriageBotAIWiring.aiWiring(flagEnabled: true, keyPresent: false))
        // Key present but flag off → off (support dialed the kill-switch back).
        XCTAssertFalse(TriageBotAIWiring.aiWiring(flagEnabled: false, keyPresent: true))
        // Both → the only true case.
        XCTAssertTrue(TriageBotAIWiring.aiWiring(flagEnabled: true, keyPresent: true))
    }
}
