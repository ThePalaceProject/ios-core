import XCTest
@testable import TriageBotCore

final class LocalClassifierTests: XCTestCase {
    private let classifier = LocalClassifier()

    // Synthetic catalog mirroring real KI shapes; isolated from the bundled
    // catalog so these tests stay deterministic when KB content evolves.
    private func makeKB(_ entries: [KBEntry]) -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "2026-05-28", entries: entries))
    }

    // MARK: - Suggest

    func testHighConfidenceMatch_returnsSuggest() {
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "spinning", "won't play", "first time", "hangs"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.4
            ),
            KBEntry(
                id: "KI-005",
                category: .signin,
                status: .fixedIn,
                fixedInVersion: "3.1.0",
                symptomKeywords: ["sign in", "placeholder", "grayed out", "can't type"],
                userFacingWorkaround: "Tap the field anyway — it's active.",
                confidenceThreshold: 0.4
            )
        ])

        let result = classifier.classify(
            userText: "my audiobook keeps spinning and won't play first time I open it",
            knowledgeBase: kb
        )

        guard case .suggest(let entryId) = result.decision else {
            return XCTFail("Expected .suggest, got \(result.decision)")
        }
        XCTAssertEqual(entryId, "KI-001")
        XCTAssertGreaterThan(result.confidence, 0.4)
        XCTAssertTrue(result.matchedKeywords.contains("audiobook"))
    }

    // MARK: - Escalate

    func testNoKeywordOverlap_returnsEscalate() {
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "spinning"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.5
            )
        ])

        let result = classifier.classify(
            userText: "my reader settings keep resetting between books",
            knowledgeBase: kb
        )

        XCTAssertEqual(result.decision, .escalate)
        XCTAssertEqual(result.confidence, 0)
    }

    func testSingleLowConfidenceMatch_returnsEscalate_doesNotOverPromise() {
        // One keyword matches but score is below threshold and no runner-up.
        // Bot must NOT suggest — escalation is the safe default.
        let kb = makeKB([
            KBEntry(
                id: "KI-EDGE",
                category: .reader,
                status: .open,
                symptomKeywords: ["reading", "missing", "page", "blank", "stuck", "broken"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.6
            )
        ])

        let result = classifier.classify(
            userText: "missing things",
            knowledgeBase: kb
        )

        XCTAssertEqual(result.decision, .escalate)
        XCTAssertLessThan(result.confidence, 0.6)
    }

    // MARK: - Disambiguate

    func testMultiplePlausibleMatches_returnsDisambiguate() {
        let kb = makeKB([
            KBEntry(
                id: "KI-A",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "playback"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.9
            ),
            KBEntry(
                id: "KI-B",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "stop"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.9
            )
        ])

        let result = classifier.classify(
            userText: "audiobook stops mid playback",
            knowledgeBase: kb
        )

        if case .disambiguate(let candidates) = result.decision {
            XCTAssertGreaterThanOrEqual(candidates.count, 2)
        } else {
            XCTFail("Expected .disambiguate, got \(result.decision)")
        }
    }

    // MARK: - Filters

    func testDistributorFilter_excludesInapplicableEntry() {
        let kb = makeKB([
            KBEntry(
                id: "KI-LCP",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "won't play"],
                distributorFilter: ["palace_marketplace"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.3
            )
        ])

        // Open Access user — entry shouldn't apply
        let openAccess = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            distributor: "open_access"
        )

        let result = classifier.classify(
            userText: "audiobook won't play",
            context: openAccess,
            knowledgeBase: kb
        )

        XCTAssertEqual(result.decision, .escalate, "Distributor mismatch must exclude the entry")
    }

    func testDistributorFilter_includesMatchingDistributor() {
        let kb = makeKB([
            KBEntry(
                id: "KI-LCP",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook", "won't play"],
                distributorFilter: ["palace_marketplace"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.3
            )
        ])

        let marketplace = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            distributor: "palace_marketplace"
        )

        let result = classifier.classify(
            userText: "audiobook won't play",
            context: marketplace,
            knowledgeBase: kb
        )

        if case .suggest(let id) = result.decision {
            XCTAssertEqual(id, "KI-LCP")
        } else {
            XCTFail("Expected suggest, got \(result.decision)")
        }
    }

    func testCategoryFilter_narrowsCandidates() {
        let kb = makeKB([
            KBEntry(
                id: "KI-AUDIO",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["won't open", "stuck"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.3
            ),
            KBEntry(
                id: "KI-PDF",
                category: .reader,
                status: .open,
                symptomKeywords: ["won't open", "stuck"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.3
            )
        ])

        let result = classifier.classify(
            userText: "won't open stuck",
            category: .reader,
            knowledgeBase: kb
        )

        if case .suggest(let id) = result.decision {
            XCTAssertEqual(id, "KI-PDF", "Category filter must restrict to reader entries")
        } else if case .disambiguate(let ids) = result.decision {
            XCTAssertFalse(ids.contains("KI-AUDIO"), "Audiobook entry must be excluded")
        } else {
            XCTFail("Expected suggest or disambiguate, got \(result.decision)")
        }
    }

    // MARK: - Smart punctuation (real iOS keyboard input)

    func testSmartApostropheInput_stillMatchesASCIIKeyword() {
        // A stock iPhone keyboard types a curly apostrophe (U+2019). The KB
        // keyword is written with an ASCII apostrophe. Before normalization this
        // matched neither the apostrophe nor the no-apostrophe variant — a
        // silent recall collapse on the app's own input method.
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["won't play", "spinning"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.4
            )
        ])

        let curly = "my audiobook won\u{2019}t play, just keeps spinning"
        let result = classifier.classify(userText: curly, knowledgeBase: kb)

        guard case .suggest(let id) = result.decision else {
            return XCTFail("Curly-apostrophe input must still match; got \(result.decision)")
        }
        XCTAssertEqual(id, "KI-001")
    }

    // MARK: - Distinct-region match counting (nested-variant guard)

    func testNestedKeywordVariants_singleWord_doesNotOverPromise() {
        // "hangs" substring-matches BOTH "hang" and "hangs". Counting raw
        // keyword hits gave 2 → cleared the >=2 confidence guard → a confident
        // suggestion off ONE word. Distinct-region counting collapses the nested
        // variants to a single region, so one word escalates instead.
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["hang", "hangs", "stuck", "won't play"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.1
            )
        ])

        let result = classifier.classify(userText: "it hangs", knowledgeBase: kb)

        XCTAssertNotEqual(
            result.decision, .suggest(entryId: "KI-001"),
            "A single word that only hits nested variants of one concept must not suggest"
        )
    }

    func testTwoDistinctConcepts_stillSuggest() {
        // Two genuinely different keyword regions ("hangs" + "spinning") remain
        // a confident match — the dedup only collapses overlapping spans.
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["hang", "hangs", "spinning", "won't play"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.1
            )
        ])

        let result = classifier.classify(userText: "it hangs and keeps spinning", knowledgeBase: kb)

        guard case .suggest(let id) = result.decision else {
            return XCTFail("Two distinct concepts must still suggest; got \(result.decision)")
        }
        XCTAssertEqual(id, "KI-001")
    }

    // MARK: - Empty input

    func testEmptyUserText_returnsEscalate() {
        let kb = makeKB([
            KBEntry(
                id: "KI-001",
                category: .audiobook,
                status: .open,
                symptomKeywords: ["audiobook"],
                userFacingWorkaround: "...",
                confidenceThreshold: 0.3
            )
        ])
        let result = classifier.classify(userText: "", knowledgeBase: kb)
        XCTAssertEqual(result.decision, .escalate)
    }
}
