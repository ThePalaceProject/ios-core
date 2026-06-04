import XCTest
@testable import TriageBotCore

/// Tests for the AI-fallback path. Three concerns:
///   1. **Sterilization** — user text MUST be redacted before it lands in
///      the prompt. This is the privacy gate.
///   2. **Prompt builder + response parser** — pure functions; pinned shape
///      so a Claude misbehavior surfaces as a failed parse, not a hallucinated
///      suggestion.
///   3. **Reducer flow** — flag-on routes through .awaitingAIClassification,
///      flag-off bypasses it; aiFallbackResolved + aiFallbackUnavailable
///      handle every Claude outcome without UX surprises.
final class AIFallbackTests: XCTestCase {

    // MARK: - Sterilization (privacy-critical)

    func testSanitize_stripsAllRedactorPatterns_beforeAnyByteLeavesDevice() {
        let user = """
        my email patron@example.com isn't accepted, barcode: 1234567890123
        pin: 4321 and the response says Authorization: Bearer leaked-token-abc-12345
        on account ABCDEF12-3456-7890-ABCD-EF1234567890
        """
        let cleaned = AIFallbackPromptBuilder.sanitize(user)

        // Each sensitive pattern must be absent from the sanitized output.
        XCTAssertFalse(cleaned.contains("patron@example.com"), "email leaked")
        XCTAssertFalse(cleaned.contains("1234567890123"), "barcode leaked")
        XCTAssertFalse(cleaned.contains("4321"), "pin leaked")
        XCTAssertFalse(cleaned.contains("leaked-token-abc-12345"), "bearer token leaked")
        XCTAssertFalse(cleaned.contains("ABCDEF12-3456-7890-ABCD-EF1234567890"), "uuid leaked")

        // Non-sensitive context survives so Claude can still match.
        XCTAssertTrue(cleaned.contains("isn't accepted"), "innocuous content stripped")
    }

    func testSanitize_preservesRegularSymptomText() {
        let user = "my audiobook stopped playing halfway through chapter three"
        let cleaned = AIFallbackPromptBuilder.sanitize(user)
        XCTAssertEqual(cleaned, user, "no-PII symptom text must pass through unchanged")
    }

    // MARK: - Prompt builder

    func testUserPrompt_includesSanitizedTextAndCatalogEntries() {
        let kb = Self.synthKB()
        let prompt = AIFallbackPromptBuilder.userPrompt(
            sanitizedUserText: "audiobook stops playing halfway",
            category: .audiobook,
            context: nil,
            knowledgeBase: kb
        )

        XCTAssertTrue(prompt.contains("audiobook stops playing halfway"))
        XCTAssertTrue(prompt.contains("KI-2026-001-audiobook-first-open-hang"))
        XCTAssertTrue(prompt.contains("Category the user picked: audiobook"))
        XCTAssertTrue(prompt.contains("Respect distributor_filter"))
        XCTAssertTrue(prompt.contains("<description>"), "User text wrapped in tags to defend against prompt injection")
    }

    func testUserPrompt_omitsInternalOnlyEntries() {
        let kb = KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-PUBLIC",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["public"],
                userFacingWorkaround: "public workaround",
                visibility: .userFacing
            ),
            KBEntry(
                id: "KI-INTERNAL",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["internal"],
                userFacingWorkaround: "internal workaround",
                visibility: .internalOnly
            )
        ]))
        let prompt = AIFallbackPromptBuilder.userPrompt(
            sanitizedUserText: "audiobook problem",
            category: .audiobook,
            context: nil,
            knowledgeBase: kb
        )
        XCTAssertTrue(prompt.contains("KI-PUBLIC"))
        XCTAssertFalse(prompt.contains("KI-INTERNAL"), "internal-only entries must not leak to Claude")
    }

    func testSystemPrompt_setsConservativeRole() {
        XCTAssertTrue(AIFallbackPromptBuilder.systemPrompt.contains("classifier"))
        XCTAssertTrue(AIFallbackPromptBuilder.systemPrompt.contains("JSON"))
        XCTAssertTrue(AIFallbackPromptBuilder.systemPrompt.contains("False positives are worse"))
    }

    // MARK: - Response parser

    func testParseResponse_validMatch_returnsSuggest() throws {
        let json = #"{"matched_entry_id": "KI-2026-001-audiobook-first-open-hang", "confidence": 0.8, "reasoning": "matches"}"#
        let result = try AIFallbackPromptBuilder.parseResponse(json, knowledgeBase: Self.synthKB())
        guard case .suggest(let id) = result.decision else {
            return XCTFail("Expected .suggest, got \(result.decision)")
        }
        XCTAssertEqual(id, "KI-2026-001-audiobook-first-open-hang")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.001)
    }

    func testParseResponse_explicitlyNullMatch_returnsEscalate() throws {
        let json = #"{"matched_entry_id": null, "confidence": 0.0, "reasoning": "no match"}"#
        let result = try AIFallbackPromptBuilder.parseResponse(json, knowledgeBase: Self.synthKB())
        XCTAssertEqual(result.decision, .escalate)
    }

    func testParseResponse_hallucinated_entryId_returnsEscalate_notWrongMatch() throws {
        // Claude invented an entry id that doesn't exist in the KB. Bot must
        // NOT route the user to a fake card — must fall back to escalate.
        let json = #"{"matched_entry_id": "KI-2099-LITERALLY-MADE-UP", "confidence": 0.95, "reasoning": "..."}"#
        let result = try AIFallbackPromptBuilder.parseResponse(json, knowledgeBase: Self.synthKB())
        XCTAssertEqual(result.decision, .escalate, "Hallucinated entry id must escalate, not surface a fake match")
    }

    func testParseResponse_lowConfidence_escalates_evenWithValidEntryId() throws {
        let json = #"{"matched_entry_id": "KI-2026-001-audiobook-first-open-hang", "confidence": 0.3, "reasoning": "uncertain"}"#
        let result = try AIFallbackPromptBuilder.parseResponse(json, knowledgeBase: Self.synthKB())
        XCTAssertEqual(result.decision, .escalate, "Low-confidence Claude match should escalate, not over-promise")
    }

    func testParseResponse_garbageInput_throws() {
        let json = "This is not JSON, sorry!"
        do {
            _ = try AIFallbackPromptBuilder.parseResponse(json, knowledgeBase: Self.synthKB())
            XCTFail("Expected throw on non-JSON input")
        } catch {
            // expected
        }
    }

    // MARK: - Reducer flow

    func testReducer_aiFallbackFlagOff_bypassesIntermediateState() {
        let reducer = ConversationReducer(knowledgeBase: Self.synthKB(), aiFallbackEnabled: false)
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.reader))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("totally novel reader problem"))
        let (final, _) = reducer.reduce(state: state, action: .userSubmittedDescription)

        // Old behavior: escalate goes straight to .drafting. No
        // .awaitingAIClassification, no .runAIFallback effect.
        if case .drafting = final.step {} else {
            XCTFail("Expected .drafting (flag off), got \(final.step)")
        }
    }

    func testReducer_aiFallbackFlagOn_routesToAwaitingAIClassification() {
        let reducer = ConversationReducer(knowledgeBase: Self.synthKB(), aiFallbackEnabled: true)
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.reader))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("totally novel reader problem"))
        let (final, effects) = reducer.reduce(state: state, action: .userSubmittedDescription)

        if case .awaitingAIClassification(let text, let cat) = final.step {
            XCTAssertEqual(text, "totally novel reader problem")
            XCTAssertEqual(cat, .reader)
        } else {
            XCTFail("Expected .awaitingAIClassification, got \(final.step)")
        }
        XCTAssertTrue(effects.contains { effect in
            if case .runAIFallback = effect { return true }
            return false
        }, "Reducer must emit .runAIFallback effect when flag is on and local escalates")
    }

    func testReducer_aiFallbackResolved_suggest_transitionsToMatched() {
        let reducer = ConversationReducer(knowledgeBase: Self.synthKB(), aiFallbackEnabled: true)
        let state = ConversationState(step: .awaitingAIClassification(userText: "x", category: .audiobook))
        let suggested = ClassificationResult(
            decision: .suggest(entryId: "KI-2026-001-audiobook-first-open-hang"),
            confidence: 0.8
        )
        let (next, effects) = reducer.reduce(state: state, action: .aiFallbackResolved(suggested))
        if case .matched(let id) = next.step {
            XCTAssertEqual(id, "KI-2026-001-audiobook-first-open-hang")
        } else {
            XCTFail("Expected .matched, got \(next.step)")
        }
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect { return e.name == "triage_ai_fallback_match" }
            return false
        })
    }

    func testReducer_aiFallbackResolved_escalate_transitionsToDrafting() {
        let reducer = ConversationReducer(knowledgeBase: Self.synthKB(), aiFallbackEnabled: true)
        let state = ConversationState(step: .awaitingAIClassification(userText: "novel", category: .reader))
        let escalate = ClassificationResult(decision: .escalate, confidence: 0)
        let (next, _) = reducer.reduce(state: state, action: .aiFallbackResolved(escalate))
        if case .drafting = next.step {} else {
            XCTFail("Expected .drafting after AI escalate, got \(next.step)")
        }
    }

    func testReducer_aiFallbackUnavailable_fallsThroughToDrafting() {
        let reducer = ConversationReducer(knowledgeBase: Self.synthKB(), aiFallbackEnabled: true)
        let state = ConversationState(step: .awaitingAIClassification(userText: "novel", category: .reader))
        let (next, effects) = reducer.reduce(state: state, action: .aiFallbackUnavailable)
        if case .drafting = next.step {} else {
            XCTFail("Expected .drafting after AI unavailable, got \(next.step)")
        }
        // Telemetry should record the unavailable event so we can monitor
        // fallback reliability in the wild.
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let e) = effect { return e.name == "triage_ai_fallback_unavailable" }
            return false
        })
    }

    // MARK: - Fixtures

    private static func synthKB() -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-2026-001-audiobook-first-open-hang",
                category: .audiobook,
                status: .open,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["spinning", "won't play"],
                userFacingWorkaround: "Tap back, tap again.",
                trustLevel: .authoritative,
                visibility: .userFacing
            ),
            KBEntry(
                id: "KI-2026-003-signin-placeholder-contrast",
                category: .signin,
                status: .fixedIn,
                fixedInVersion: "3.1.0",
                symptomKeywords: ["grayed out"],
                userFacingWorkaround: "Tap to type.",
                trustLevel: .authoritative,
                visibility: .userFacing
            )
        ]))
    }
}
