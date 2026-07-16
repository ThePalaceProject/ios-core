import XCTest
@testable import TriageBotCore

/// PP-4805 — the highest-value privacy leak is a patron TYPING a PIN /
/// password / barcode into the free-text description or the follow-up answer.
/// These tests pin each new redaction pattern (positive + decoy-negative so a
/// pattern that's too greedy fails just as loudly as one that's too weak) and
/// prove the reducer routes ALL user-authored text through the redactor before
/// it can reach a draft, the email body, or the JSON attachment.
final class FreeTextRedactionTests: XCTestCase {
    private let redactor = ContextRedactor()

    // MARK: - PIN adjacency (no colon — "my pin is 1234")

    func testRedactsPinStatedInProse() {
        let output = redactor.redactLine("hi, my pin is 1234 by the way")
        XCTAssertFalse(output.contains("1234"), "A prose-stated PIN must be stripped")
    }

    func testRedactsPasscodeStatedInProse() {
        let output = redactor.redactLine("passcode 8675 didn't work")
        XCTAssertFalse(output.contains("8675"))
    }

    func testPinAdjacency_decoy_leavesSpinningWheelUntouched() {
        // "spinning" contains the letters p-i-n but is not the word "pin".
        // A pattern that redacts it would nuke the audiobook KB keyword.
        let input = "the audiobook is spinning and never plays"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    func testPinAdjacency_decoy_leavesPinWithNoNumberUntouched() {
        let input = "please pin this message for me"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - password: <token>

    func testRedactsPasswordColonToken() {
        let output = redactor.redactLine("password: hunter2swordfish")
        XCTAssertFalse(output.contains("hunter2swordfish"))
    }

    func testPassword_decoy_leavesPasswordResetProseUntouched() {
        // No token follows — "password reset requested" must survive so
        // patrons can describe a password *problem* without it vanishing.
        let input = "I clicked password reset requested twice"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - standalone 10-14 digit barcode / card number

    func testRedactsStandaloneBarcodeDigits() {
        let output = redactor.redactLine("my card 21234000012345 stopped working")
        XCTAssertFalse(output.contains("21234000012345"))
    }

    func testBarcode_decoy_leavesShortNumbersUntouched() {
        // A 4-digit year and a 3-digit error code must survive.
        let input = "error 500 happened in 2026"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - generic Cookie / Set-Cookie value

    func testRedactsGenericSetCookieValue() {
        let output = redactor.redactLine("Set-Cookie: authsession=Zm9vYmFyMTIzNA")
        XCTAssertFalse(output.contains("Zm9vYmFyMTIzNA"))
    }

    func testCookie_decoy_leavesCookieProseUntouched() {
        // No key=value pair — patron mentioning "cookie policy" survives.
        let input = "the cookie policy dialog blocks me"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - key/value credential encodings (JSON / query / form)

    func testRedactsAccessTokenInJSON() {
        let output = redactor.redactLine(#"{"access_token":"aaa.bbb.ccc","x":1}"#)
        XCTAssertFalse(output.contains("aaa.bbb.ccc"))
    }

    func testRedactsRefreshTokenInQueryString() {
        let output = redactor.redactLine("GET /cb?refresh_token=SECRETVALUE123&state=ok")
        XCTAssertFalse(output.contains("SECRETVALUE123"))
    }

    func testRedactsClientSecretAndApiKey() {
        let output = redactor.redactLine("client_secret=abc123XYZ api_key=zzz999QQQ")
        XCTAssertFalse(output.contains("abc123XYZ"))
        XCTAssertFalse(output.contains("zzz999QQQ"))
    }

    func testKeyValueCreds_decoy_leavesTokenizerUntouched() {
        // "tokenizer=swift" starts with "token" but is a different word —
        // must not be redacted, or config/debug prose gets mangled.
        let input = "tokenizer=swift stage=ready"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - x-api-key header

    func testRedactsXApiKeyHeader() {
        let output = redactor.redactLine("x-api-key: sk-live-abcdef123456")
        XCTAssertFalse(output.contains("sk-live-abcdef123456"))
    }

    func testXApiKey_decoy_leavesApiVersionHeaderUntouched() {
        let input = "x-api-version: 2"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - standalone JWT (eyJ...)

    func testRedactsStandaloneJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4"
        let output = redactor.redactLine("token was \(jwt) apparently")
        XCTAssertFalse(output.contains(jwt))
    }

    func testJWT_decoy_leavesEyeballWordUntouched() {
        let input = "keep an eyeball on the eyewear section"
        XCTAssertEqual(redactor.redactLine(input), input)
    }

    // MARK: - crashlytics fingerprints routed through redactLine

    func testRedactSnapshot_redactsCrashlyticsFingerprints() {
        let raw = ContextSnapshot(
            appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2",
            crashlyticsFingerprints: ["frame: my pin is 4321 in stack"]
        )
        let redacted = redactor.redact(raw)
        XCTAssertFalse(
            redacted.crashlyticsFingerprints[0].contains("4321"),
            "A PIN accidentally captured in a crash fingerprint must be stripped"
        )
    }

    // MARK: - Reducer end-to-end: typed secrets never reach the ticket

    private func makeEscalatingReducer() -> ConversationReducer {
        // Empty KB → any free-text description escalates to a draft, which is
        // exactly the path where the raw user text would otherwise land in a
        // ticket verbatim.
        let catalog = KBCatalog(version: "test", updatedAt: "2026-07-16", entries: [])
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    private func extractDraft(_ step: ConversationState.Step) -> TicketDraft? {
        switch step {
        case .drafting(let d), .submitting(let d): return d
        case .awaitingEscalationFollowUp(_, let d): return d
        default: return nil
        }
    }

    func testEscalatedDescription_redactsTypedSecrets_inDraftEmailAndAttachment() {
        let reducer = makeEscalatingReducer()
        let secretPin = "1234"
        let secretPassword = "hunter2swordfish"
        let secretBarcode = "21234000012345"
        let typed = "my pin is \(secretPin), password: \(secretPassword), card \(secretBarcode)"

        var state = ConversationState(step: .awaitingDescription(category: .other))
        (state, _) = reducer.reduce(state: state, action: .inputChanged(typed))
        let (drafted, _) = reducer.reduce(state: state, action: .userSubmittedDescription)

        guard let draft = extractDraft(drafted.step) else {
            return XCTFail("Expected an escalation draft, got \(drafted.step)")
        }

        for secret in [secretPin, secretPassword, secretBarcode] {
            XCTAssertFalse(draft.userDescription.contains(secret), "Secret \(secret) leaked into draft.userDescription")
            XCTAssertFalse(TicketEmailComposition.subject(for: draft).contains(secret), "Secret \(secret) leaked into email subject")
            XCTAssertFalse(TicketEmailComposition.body(for: draft).contains(secret), "Secret \(secret) leaked into email body")
            for attachment in TicketEmailComposition.attachments(for: draft) {
                let text = String(data: attachment.data, encoding: .utf8) ?? ""
                XCTAssertFalse(text.contains(secret), "Secret \(secret) leaked into attachment \(attachment.fileName)")
            }
        }
    }

    func testEscalationFollowUpAnswer_redactsTypedSecrets_inDraftAndEmail() {
        let reducer = makeEscalatingReducer()
        let secret = "9876"
        let pendingDraft = TicketDraft(
            userDescription: "app broke",
            category: .signin,
            context: ContextSnapshot(appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2")
        )
        let state = ConversationState(step: .awaitingEscalationFollowUp(prompt: "Which library?", pendingDraft: pendingDraft))

        let (next, _) = reducer.reduce(state: state, action: .userAnsweredEscalationFollowUp(answer: "my pin is \(secret)"))

        guard case .drafting(let draft) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertFalse(draft.escalationFollowUp?.answer?.contains(secret) ?? false, "Secret leaked into follow-up answer on draft")
        XCTAssertFalse(TicketEmailComposition.body(for: draft).contains(secret), "Secret leaked into email body via follow-up answer")
    }
}
