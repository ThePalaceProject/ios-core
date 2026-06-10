//
//  SupportSectionDecisionTests.swift
//  PalaceTests
//
//  PP-4542 / F-012: when the triage bot is disabled (production Firebase
//  default), the Settings Support section must still appear with a legacy
//  email report path. These tests pin the pure decision that the view body
//  renders from, so the fallback can't silently disappear again.
//

import XCTest
@testable import Palace

final class SupportSectionDecisionTests: XCTestCase {

    private let generalFallback = "support@thepalaceproject.org"

    // MARK: bot ON

    func testDecide_botEnabled_choosesTriageBot_regardlessOfEmail() {
        // With email present.
        XCTAssertEqual(
            SupportSectionDecision.decide(isTriageBotEnabled: true, supportEmail: "library@example.org"),
            .triageBot
        )
        // And with no email — the bot path never falls back to email.
        XCTAssertEqual(
            SupportSectionDecision.decide(isTriageBotEnabled: true, supportEmail: nil),
            .triageBot
        )
    }

    // MARK: bot OFF — section still present, legacy email path

    func testDecide_botDisabled_withAccountEmail_usesAccountEmail() {
        let decision = SupportSectionDecision.decide(
            isTriageBotEnabled: false,
            supportEmail: "library@example.org"
        )
        XCTAssertEqual(decision, .legacyEmail(address: "library@example.org"))
    }

    /// The critical regression case: bot OFF + the current library exposes no
    /// support email. Support MUST still be reachable via the general fallback,
    /// never a no-op / missing section.
    func testDecide_botDisabled_withoutAccountEmail_usesGeneralFallback() {
        let decision = SupportSectionDecision.decide(
            isTriageBotEnabled: false,
            supportEmail: nil
        )
        XCTAssertEqual(decision, .legacyEmail(address: generalFallback))
    }

    /// Empty-string email is treated as "no usable address" and must fall back,
    /// not produce a `.legacyEmail(address: "")` that would compose to nobody.
    func testDecide_botDisabled_withEmptyEmail_usesGeneralFallback() {
        let decision = SupportSectionDecision.decide(
            isTriageBotEnabled: false,
            supportEmail: ""
        )
        XCTAssertEqual(decision, .legacyEmail(address: generalFallback))
    }

    // MARK: address accessor used by the view to drive beginComposing(to:)

    func testEmailAddress_isNilForTriageBot_andResolvedForLegacy() {
        XCTAssertNil(SupportSectionDecision.triageBot.emailAddress)
        XCTAssertEqual(
            SupportSectionDecision.legacyEmail(address: "a@b.org").emailAddress,
            "a@b.org"
        )
    }
}
