import XCTest
@testable import TriageBotCore

/// Detection decides which remedies the bot SKIPS. A false positive silently
/// removes a step the patron never took — and the step removed is often the one
/// most likely to help them, because the phrase that triggered it was them
/// describing their problem rather than their attempts.
///
/// The rule the file states for itself is past-tense statements of having done
/// the thing. These pin it.
final class RemedyDetectionAccuracyTests: XCTestCase {

    private let detector = RemedyDetector()

    /// The worst live false positive: "switched libraries" is KI-2026-002's
    /// SYMPTOM keyword, verbatim. A patron reporting that switching libraries
    /// broke something had `switchLibrary` marked as already-tried, which skips
    /// the library ladder's first rung — the rung telling them to check which
    /// library is selected, which is the likeliest fix for that exact complaint.
    func testDescribingALibrarySwitchAsTheCause_isNotAnAttemptedRemedy() {
        XCTAssertFalse(
            detector.alreadyTried(in: "I switched libraries and now my books are gone").contains(.switchLibrary),
            "the patron named their trigger, not a remedy they tried")
        XCTAssertFalse(
            detector.alreadyTried(in: "it crashed after I changed library").contains(.switchLibrary))
        // A deliberate attempt still counts.
        XCTAssertTrue(
            detector.alreadyTried(in: "I tried my other library and it does the same thing").contains(.switchLibrary))
    }

    /// "pull to refresh" is imperative, not past tense — it matches a patron
    /// ASKING how to do it, and skips the safest rung we have.
    func testAskingHowToRefresh_isNotHavingRefreshed() {
        XCTAssertFalse(detector.alreadyTried(in: "how do I pull to refresh?").contains(.pullToRefresh))
        XCTAssertFalse(detector.alreadyTried(in: "should I pull to refresh").contains(.pullToRefresh))
        XCTAssertTrue(detector.alreadyTried(in: "I pulled down to refresh and nothing changed").contains(.pullToRefresh))
    }

    /// A phone that restarts itself is a symptom. A phone the patron restarted
    /// is a remedy. Bare "rebooted" cannot tell them apart.
    func testASpontaneousRestart_isNotARemedyTheyTried() {
        XCTAssertFalse(detector.alreadyTried(in: "my phone rebooted itself while the audiobook was playing").contains(.restartDevice))
        XCTAssertTrue(detector.alreadyTried(in: "I rebooted my phone and tried again").contains(.restartDevice))
    }

    /// "up to date" about a card or about iOS is not a claim about Palace.
    func testUpToDateAboutSomethingElse_isNotAnAppUpdate() {
        XCTAssertFalse(detector.alreadyTried(in: "my library card is up to date").contains(.updateApp))
        XCTAssertFalse(detector.alreadyTried(in: "I keep my iphone up to date").contains(.updateApp))
        XCTAssertTrue(detector.alreadyTried(in: "I updated the app and it still fails").contains(.updateApp))
    }

    /// The phrase lists match contiguous token runs, so a natural repetition
    /// breaks them: "signed out and back" does not occur in "signed out and
    /// SIGNED back in", which is how most people write it.
    func testTheMostNaturalSignOutPhrasing_isDetected() {
        for text in ["I signed out and signed back in",
                     "logged out and logged back in again",
                     "I signed out then signed back in and it still asks me to log in"] {
            XCTAssertTrue(detector.alreadyTried(in: text).contains(.signOutIn),
                          "missed a sign-out claim in: \(text)")
        }
    }

    /// "iPhone" is the word patrons actually use, and it was the one device noun
    /// missing from the restart list.
    func testCommonRestartAndNetworkPhrasings_areDetected() {
        XCTAssertTrue(detector.alreadyTried(in: "I restarted my iphone twice").contains(.restartDevice))
        XCTAssertTrue(detector.alreadyTried(in: "turned it off and on again").contains(.restartDevice))
        XCTAssertTrue(detector.alreadyTried(in: "I turned airplane mode on and off").contains(.toggleNetwork))
        XCTAssertTrue(detector.alreadyTried(in: "tried a different network, no luck").contains(.toggleNetwork))
    }
}
