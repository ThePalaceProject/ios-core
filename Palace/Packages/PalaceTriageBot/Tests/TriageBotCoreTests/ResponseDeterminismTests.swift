import XCTest
@testable import TriageBotCore

/// Response-level determinism: given the same user input, does the bot
/// produce the same answer every time?
///
/// The previous suite asks "do tests pass?" — useful but indirect. This
/// suite asks the user's actual question: "if I type X, do I always get the
/// same response?" — by running the classifier and full reducer flow N times
/// per input and asserting every iteration produces a bit-identical result.
///
/// What we're proving:
///   - Classifier: same `ClassificationResult` (decision, confidence,
///     matchedKeywords ordering, consideredEntryIds ordering)
///   - Reducer: same final `ConversationState.step` after running the same
///     scripted Action sequence
///
/// What this rules out: dict iteration order leaking through, hidden
/// randomness, time-based branches, async-task race ordering.
final class ResponseDeterminismTests: XCTestCase {

    private static let iterations = 100

    // MARK: - Classifier determinism

    /// Each representative input is run 100 times. We assert that all 100
    /// runs produce the SAME ClassificationResult — same entry id, same
    /// confidence, same matched keywords ARRAY (order matters), same
    /// considered-ids ARRAY (order matters).
    func testClassifier_sameInputAlwaysSameOutput() throws {
        let kb = try Self.loadCatalog()
        let classifier = LocalClassifier()

        struct Probe {
            let label: String
            let userText: String
            let category: KBCategory?
            let context: ContextSnapshot?
        }

        let marketplace = ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        let probes: [Probe] = [
            // Audiobook hang — classic suggest path
            .init(label: "audiobook-spinning-first-time",
                  userText: "my audiobook keeps spinning and won't play the first time I open it",
                  category: .audiobook, context: marketplace),
            // Audiobook hang — paraphrase
            .init(label: "audiobook-sits-there",
                  userText: "audiobook just sits there spinning, nothing happens when I tap play",
                  category: .audiobook, context: marketplace),
            // Sign-in placeholder — fixed-in entry
            .init(label: "signin-grayed-fields",
                  userText: "the sign-in page shows grayed-out boxes and I'm never prompted to enter my card",
                  category: .signin, context: nil),
            // Wrong library — user-error category
            .init(label: "wrong-library",
                  userText: "the book I downloaded on my phone doesn't appear on my iPad",
                  category: .library, context: nil),
            // CarPlay crash
            .init(label: "carplay-crash",
                  userText: "Palace crashes the moment I plug into CarPlay",
                  category: .audiobook, context: nil),
            // Hold-ready desync
            .init(label: "hold-desync",
                  userText: "got a notification that my hold is ready but it's not in my holds list",
                  category: .library, context: nil),
            // PDF blank
            .init(label: "pdf-blank",
                  userText: "my pdf is stuck on the cover and won't open",
                  category: .reader, context: marketplace),
            // Novel symptom — escalate path
            .init(label: "novel-font-reset",
                  userText: "my reader font size resets to defaults every time I open a book",
                  category: .reader, context: nil),
            // Negative — must reject
            .init(label: "decoy-bearer",
                  userText: "I am a Bearer of good news, my audiobook plays perfectly",
                  category: .audiobook, context: marketplace),
            // Edge — disambiguation territory
            .init(label: "audiobook-generic",
                  userText: "audiobook problem",
                  category: .audiobook, context: marketplace),
        ]

        for probe in probes {
            var observations: [ClassificationResult] = []
            for _ in 0..<Self.iterations {
                let r = classifier.classify(
                    userText: probe.userText,
                    category: probe.category,
                    context: probe.context,
                    knowledgeBase: kb
                )
                observations.append(r)
            }

            // All observations must be equal to the first.
            let first = observations[0]
            for (i, obs) in observations.enumerated().dropFirst() {
                XCTAssertEqual(obs.decision, first.decision,
                    "[\(probe.label)] decision drift at iter \(i): expected \(first.decision), got \(obs.decision)")
                XCTAssertEqual(obs.confidence, first.confidence,
                    "[\(probe.label)] confidence drift at iter \(i): expected \(first.confidence), got \(obs.confidence)")
                XCTAssertEqual(obs.matchedKeywords, first.matchedKeywords,
                    "[\(probe.label)] matched-keyword ORDER drift at iter \(i): expected \(first.matchedKeywords), got \(obs.matchedKeywords)")
                XCTAssertEqual(obs.consideredEntryIds, first.consideredEntryIds,
                    "[\(probe.label)] considered-ids ORDER drift at iter \(i): expected \(first.consideredEntryIds), got \(obs.consideredEntryIds)")
            }
        }
    }

    // MARK: - Reducer determinism (scripted conversations)

    /// Each scripted conversation is replayed 100 times against fresh state.
    /// We assert the final state is bit-identical and the message log is
    /// identical too. Any divergence means non-determinism leaked through
    /// the reducer's effect pipeline or a downstream classifier call.
    func testReducer_sameScriptAlwaysSameFinalState() throws {
        let kb = try Self.loadCatalog()
        let reducer = ConversationReducer(knowledgeBase: kb)

        let marketplace = ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        struct Script {
            let label: String
            let actions: [ConversationAction]
        }

        let scripts: [Script] = [
            .init(label: "happy-audiobook-match-notify-me",
                  actions: [
                    .start,
                    .contextLoaded(marketplace),
                    .userTappedCategory(.audiobook),
                    .inputChanged("my audiobook keeps spinning and won't play the first time I open it"),
                    .userSubmittedDescription,
                    .userTappedNotifyMeOnFix(entryId: "KI-2026-001-audiobook-first-open-hang")
                  ]),
            .init(label: "happy-audiobook-match-file-anyway",
                  actions: [
                    .start,
                    .contextLoaded(marketplace),
                    .userTappedCategory(.audiobook),
                    .inputChanged("audiobook just sits there spinning"),
                    .userSubmittedDescription,
                    .userTappedFileTicketAnyway,
                    .userConfirmedTicketSubmit,
                    .ticketSubmitted(TicketReceipt(ticketId: "TEST-FIXED-RECEIPT", submittedAt: Date(timeIntervalSince1970: 0)))
                  ]),
            .init(label: "escalate-novel-symptom",
                  actions: [
                    .start,
                    .contextLoaded(marketplace),
                    .userTappedCategory(.reader),
                    .inputChanged("my font size resets to defaults every time"),
                    .userSubmittedDescription,
                    .userConfirmedTicketSubmit,
                    .ticketSubmitted(TicketReceipt(ticketId: "TEST-FIXED-RECEIPT", submittedAt: Date(timeIntervalSince1970: 0)))
                  ]),
            .init(label: "submission-failed-recovery",
                  actions: [
                    .start,
                    .contextLoaded(marketplace),
                    .userTappedCategory(.reader),
                    .inputChanged("novel reader issue we don't know about"),
                    .userSubmittedDescription,
                    .userConfirmedTicketSubmit,
                    .ticketSubmissionFailed("network unavailable")
                  ]),
            .init(label: "cancel-mid-flow",
                  actions: [
                    .start,
                    .contextLoaded(marketplace),
                    .userTappedCategory(.signin),
                    .inputChanged("grayed out fields"),
                    .userSubmittedDescription,
                    .userTappedFileTicketAnyway,
                    .userCancelledTicketSubmit
                  ])
        ]

        for script in scripts {
            var finalStates: [ConversationState] = []
            for _ in 0..<Self.iterations {
                var state = ConversationState()
                for action in script.actions {
                    let (next, _) = reducer.reduce(state: state, action: action)
                    state = next
                }
                finalStates.append(state)
            }

            let reference = finalStates[0]
            for (i, s) in finalStates.enumerated().dropFirst() {
                // Compare step + classifier-derived state. Message IDs are
                // intentionally NOT compared — they use UUID() at runtime so
                // each new ConversationMessage gets a unique id even from the
                // same script (this is desired; SwiftUI needs stable but
                // unique identity per item). Compare message KIND order
                // instead, which is what the UI renders.
                XCTAssertEqual(s.step, reference.step,
                    "[\(script.label)] final step drift at iter \(i): \(reference.step) vs \(s.step)")
                XCTAssertEqual(s.messages.map(\.kind), reference.messages.map(\.kind),
                    "[\(script.label)] message-kind sequence drift at iter \(i)")
                XCTAssertEqual(s.messages.map(\.sender), reference.messages.map(\.sender),
                    "[\(script.label)] message-sender sequence drift at iter \(i)")
                XCTAssertEqual(s.lastClassification, reference.lastClassification,
                    "[\(script.label)] lastClassification drift at iter \(i)")
                XCTAssertEqual(s.context, reference.context,
                    "[\(script.label)] context drift at iter \(i)")
            }
        }
    }

    // MARK: - Iteration order under KB shuffling

    /// Does the classifier's output change if the KB entries are presented
    /// in a different order? It shouldn't — the entry IDs are stable, and
    /// classify() should rank by score not by insertion position.
    /// Validates that there's no hidden "first entry wins on tie" leak.
    func testClassifier_resultStable_whenCatalogShuffled() throws {
        let original = try Self.loadCatalog()
        let userText = "my audiobook keeps spinning and won't play the first time"
        let marketplace = ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace"
        )

        let baselineResult = LocalClassifier().classify(
            userText: userText,
            category: .audiobook,
            context: marketplace,
            knowledgeBase: original
        )

        // Deterministic permutations of the entries (rotation by N) so the
        // test itself stays reproducible. Bounded by catalog size.
        let entries = original.catalog.entries
        let maxRotation = max(1, entries.count - 1)
        for rotation in 1...maxRotation {
            let rotated = Array(entries[rotation...]) + Array(entries[..<rotation])
            let shuffledKB = KnowledgeBase(catalog: KBCatalog(
                version: original.catalog.version,
                updatedAt: original.catalog.updatedAt,
                entries: rotated
            ))
            let result = LocalClassifier().classify(
                userText: userText,
                category: .audiobook,
                context: marketplace,
                knowledgeBase: shuffledKB
            )
            XCTAssertEqual(result.decision, baselineResult.decision,
                "Classifier decision changed under KB rotation \(rotation) — entry ordering leaks into output")
            XCTAssertEqual(result.confidence, baselineResult.confidence,
                "Confidence changed under KB rotation \(rotation)")
            // Considered IDs WILL differ in order because the rotation
            // changes filter() input order. We only assert the SET is the
            // same.
            XCTAssertEqual(Set(result.consideredEntryIds), Set(baselineResult.consideredEntryIds),
                "Considered-ids set changed under KB rotation \(rotation)")
        }
    }

    // MARK: - Helpers

    private static func loadCatalog() throws -> KnowledgeBase {
        let source = BundledCatalogSource()
        var caught: Error?
        var catalog: KBCatalog!
        let group = DispatchGroup()
        group.enter()
        Task {
            do { catalog = try await source.loadCatalog() } catch { caught = error }
            group.leave()
        }
        group.wait()
        if let e = caught { throw e }
        return KnowledgeBase(catalog: catalog)
    }
}
