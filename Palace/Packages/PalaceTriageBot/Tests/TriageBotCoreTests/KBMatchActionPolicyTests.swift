import XCTest
@testable import TriageBotCore

/// Pins the suppression of the notify-me-on-fix affordance.
///
/// The affordance previously rendered whenever an entry carried a
/// `fixed_in_version`, and tapping it produced a synthetic local receipt plus a
/// reassuring message. No notification was ever scheduled and no mechanism
/// existed to deliver one, so the card promised the patron something the app
/// could not do. These tests fail if the affordance is re-enabled before a real
/// delivery path exists.
final class KBMatchActionPolicyTests: XCTestCase {

    /// The case that used to show the chip. This is the one that matters: a
    /// regression that restores the old `entry.fixedInVersion != nil` rule
    /// fails here rather than shipping a false promise.
    func testNotifyMeOnFix_whenEntryHasFixVersion_staysHidden() {
        XCTAssertFalse(
            KBMatchActionPolicy.showsNotifyMeOnFix(entryHasFixVersion: true),
            "Notify-me must stay hidden while no notification can be delivered"
        )
    }

    func testNotifyMeOnFix_whenEntryHasNoFixVersion_staysHidden() {
        XCTAssertFalse(
            KBMatchActionPolicy.showsNotifyMeOnFix(entryHasFixVersion: false)
        )
    }
}
