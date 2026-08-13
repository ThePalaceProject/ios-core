import XCTest
@testable import TriageBotCore

/// Directly pins the two mechanisms the end-to-end benchmark only exercises
/// incidentally: the distinct-region merge and the four-conjunct suggest guard.
/// Each test names the production mutant it kills so a refactor that breaks the
/// logic fails by construction, not by luck.
final class ClassifierInternalsTests: XCTestCase {

    private let classifier = LocalClassifier()

    private func makeKB(_ entries: [KBEntry]) -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "2026-07-20", entries: entries))
    }

    private func knownIssue(
        _ id: String,
        _ keywords: [String],
        corroborating: [String]? = nil,
        threshold: Double = 0.0
    ) -> KBEntry {
        KBEntry(id: id, category: .other, status: .open,
                symptomKeywords: keywords, corroboratingKeywords: corroborating,
                userFacingWorkaround: "Do the thing to fix it.",
                confidenceThreshold: threshold)
    }

    // MARK: - distinctMatchRegionCount (kills M2 merge-boundary, pins M8 init)

    func testRegionCount_touchingRangesAreTwoRegions() {
        // "sign"[0..4) touches "in"[4..6): lowerBound(4) >= currentUpper(4) → new
        // cluster. If the boundary were `>` they would merge into one.
        XCTAssertEqual(LocalClassifier.distinctMatchRegionCount(of: ["sign", "in"], in: "signin"), 2)
    }

    func testRegionCount_nestedRangesAreOneRegion() {
        XCTAssertEqual(
            LocalClassifier.distinctMatchRegionCount(of: ["won't download", "download"], in: "won't download"),
            1
        )
    }

    func testRegionCount_disjointRangesCountSeparately() {
        XCTAssertEqual(
            LocalClassifier.distinctMatchRegionCount(of: ["alpha", "gamma"], in: "alpha beta gamma"),
            2
        )
    }

    func testRegionCount_chainedOverlapsCollapseToOne() {
        // "a b"[0..3), "b c"[2..5) overlap and chain-extend into a single cluster.
        XCTAssertEqual(LocalClassifier.distinctMatchRegionCount(of: ["a b", "b c"], in: "a b c"), 1)
    }

    func testRegionCount_emptyKeywordIsSkipped() {
        XCTAssertEqual(LocalClassifier.distinctMatchRegionCount(of: ["", "alpha"], in: "alpha"), 1)
    }

    func testRegionCount_noMatchIsZero() {
        XCTAssertEqual(LocalClassifier.distinctMatchRegionCount(of: ["zzz"], in: "alpha"), 0)
    }

    func testRegionCount_keywordLongerThanInputIsZero() {
        XCTAssertEqual(LocalClassifier.distinctMatchRegionCount(of: ["alphabeta"], in: "alpha"), 0)
    }

    // MARK: - Score scale (kills M7 kSaturation, M13 cap)

    func testScoreScale_quantizesAndCapsAtOne() {
        let kb = makeKB([knownIssue("K", ["alpha", "beta", "gamma", "delta", "epsilon"])])
        func confidence(_ text: String) -> Double {
            classifier.classify(userText: text, knowledgeBase: kb).confidence
        }
        XCTAssertEqual(confidence("alpha"), 1.0 / 3.0, accuracy: 0.0001)                       // 1 region
        XCTAssertEqual(confidence("alpha beta"), 2.0 / 3.0, accuracy: 0.0001)                  // 2 regions
        XCTAssertEqual(confidence("alpha beta gamma"), 1.0, accuracy: 0.0001)                  // 3 regions
        XCTAssertEqual(confidence("alpha beta gamma delta epsilon"), 1.0, accuracy: 0.0001)    // 5 → capped
    }

    // MARK: - Suggest guard decision table

    func testGuard_allConjunctsPass_suggests() {
        let kb = makeKB([knownIssue("K", ["alpha", "beta"])])
        XCTAssertEqual(classifier.classify(userText: "alpha beta", knowledgeBase: kb).decision,
                       .suggest(entryId: "K"))
    }

    func testGuard_scoreBelowEntryThreshold_doesNotSuggest() {
        // 2 regions → 0.667, entry demands 0.7. THE test the mislabeled
        // "single low confidence" test only pretended to be. Kills M1: flip the
        // threshold check to `true` and this suggests.
        let kb = makeKB([knownIssue("K", ["alpha", "beta"], threshold: 0.7)])
        let decision = classifier.classify(userText: "alpha beta", knowledgeBase: kb).decision
        XCTAssertNotEqual(decision, .suggest(entryId: "K"),
                          "0.667 does not clear a 0.7 threshold — must not suggest")
    }

    func testGuard_threeRegionsClearHigherThreshold_suggests() {
        let kb = makeKB([knownIssue("K", ["alpha", "beta", "gamma"], threshold: 0.7)])
        XCTAssertEqual(classifier.classify(userText: "alpha beta gamma", knowledgeBase: kb).decision,
                       .suggest(entryId: "K"))
    }

    /// One STRONG region is sufficient. This is the behavior change that made the
    /// bot usable: a patron naming the problem once gets the answer.
    func testGuard_knownIssueSingleStrongRegion_suggests() {
        let kb = makeKB([knownIssue("K", ["alpha", "beta"])])
        XCTAssertEqual(classifier.classify(userText: "alpha only", knowledgeBase: kb).decision,
                       .suggest(entryId: "K"))
    }

    /// One WEAK region is not, however many of them there are. Corroborating
    /// keywords shade confidence; they never carry a suggestion alone. Kills the
    /// mutant that drops the strong-evidence conjunct from the suggest guard.
    func testGuard_knownIssueWeakRegionsOnly_escalates() {
        let kb = makeKB([knownIssue("K", ["alpha"], corroborating: ["beta", "gamma"])])
        XCTAssertEqual(classifier.classify(userText: "beta and gamma", knowledgeBase: kb).decision,
                       .escalate,
                       "two weak matches are still weak — only strong evidence may carry a suggestion")
    }

    /// Weak evidence still counts toward the score once a strong match exists —
    /// that is the whole point of keeping it rather than deleting it. Strong(1) +
    /// weak(1) = 1.5/3 = 0.5, which clears a 0.4 threshold that strong alone
    /// (1/3 = 0.333) would not.
    func testScoring_corroboratingEvidenceRaisesConfidenceOnceStrongMatchExists() {
        let kb = makeKB([knownIssue("K", ["alpha"], corroborating: ["beta"], threshold: 0.4)])
        XCTAssertEqual(classifier.classify(userText: "alpha beta", knowledgeBase: kb).decision,
                       .suggest(entryId: "K"))
        XCTAssertEqual(classifier.classify(userText: "alpha only", knowledgeBase: kb).decision,
                       .escalate,
                       "strong alone scores 0.333 and must not clear a 0.4 threshold")
    }

    func testGuard_tiedRegionCounts_disambiguates() {
        // Two entries, 2 regions each → matchCountMargin 0 → no clear leader.
        let kb = makeKB([knownIssue("A", ["alpha", "beta"]), knownIssue("B", ["alpha", "beta"])])
        guard case .disambiguate(let c) = classifier.classify(userText: "alpha beta", knowledgeBase: kb).decision else {
            return XCTFail("tied region counts must disambiguate")
        }
        XCTAssertEqual(Set(c), ["A", "B"])
    }

    func testGuard_runnerUpSaturated_disambiguates() {
        // Both saturated (3 regions each) → even a tie of saturated cards is
        // genuine ambiguity, not a confident pick. Kills M4 with a dedicated case.
        let kb = makeKB([
            knownIssue("A", ["alpha", "beta", "gamma"]),
            knownIssue("B", ["alpha", "beta", "gamma"])
        ])
        if case .suggest = classifier.classify(userText: "alpha beta gamma", knowledgeBase: kb).decision {
            XCTFail("two saturated matches must not produce a confident suggest")
        }
    }

    // MARK: - Per-kind floor (kills M5/M6 with dedicated symmetric cases)

    func testHowTo_singleRegion_suggests() {
        let howTo = KBEntry(id: "H", category: .other, kind: .howTo,
                            symptomKeywords: ["switch libraries"],
                            userFacingWorkaround: "Tap the Palace logo, then pick a library.",
                            confidenceThreshold: 0.1)
        let kb = makeKB([howTo])
        XCTAssertEqual(classifier.classify(userText: "how do I switch libraries", knowledgeBase: kb).decision,
                       .suggest(entryId: "H"))
    }

    /// The suggest floor diverges on keyword STRENGTH, not on entry KIND.
    ///
    /// This replaces a paired assertion that a 1-region input suggested for
    /// how_to and escalated for known_issue. That divergence was an artifact of
    /// the per-kind count floor: `how_to` was allowed one region because its
    /// keywords are lint-forced to be specific multi-word phrases, while
    /// `known_issue` needed two because its keyword list mixed specific phrases
    /// with generic words. Making strength explicit removes the need to
    /// approximate it by kind — so an identical strong match now behaves
    /// identically for both, and the axis that actually decides is which list the
    /// keyword came from.
    func testSuggestFloor_divergesByKeywordStrength_notByEntryKind() {
        let howTo = KBEntry(id: "H", category: .other, kind: .howTo,
                            symptomKeywords: ["magicphrase"],
                            userFacingWorkaround: "Here is how you do the thing.",
                            confidenceThreshold: 0.1)
        let known = knownIssue("K", ["magicphrase"], threshold: 0.1)

        // Same input, same strength, both kinds → same decision. Kills the mutant
        // that reintroduces a kind-specific floor.
        XCTAssertEqual(classifier.classify(userText: "magicphrase", knowledgeBase: makeKB([howTo])).decision,
                       .suggest(entryId: "H"))
        XCTAssertEqual(classifier.classify(userText: "magicphrase", knowledgeBase: makeKB([known])).decision,
                       .suggest(entryId: "K"))

        // Same input, same kind, weak instead of strong → escalates. Strength is
        // the live axis.
        let weakKnown = knownIssue("W", ["unrelated"], corroborating: ["magicphrase"], threshold: 0.1)
        XCTAssertEqual(classifier.classify(userText: "magicphrase", knowledgeBase: makeKB([weakKnown])).decision,
                       .escalate)
    }

    // MARK: - Cross-kind collision (pins the margin rationale)

    func testCrossKind_richerKnownIssueBeatsHowTo() {
        let known = knownIssue("K", ["cannot add", "second library"])
        let howTo = KBEntry(id: "H", category: .other, kind: .howTo,
                            symptomKeywords: ["switch libraries"],
                            userFacingWorkaround: "Tap the Palace logo to switch.",
                            confidenceThreshold: 0.1)
        let kb = makeKB([known, howTo])
        // 2 regions (known) vs 1 region (how_to) → known leads by margin.
        XCTAssertEqual(
            classifier.classify(userText: "I cannot add a second library and want to switch libraries",
                                knowledgeBase: kb).decision,
            .suggest(entryId: "K")
        )
    }

    // MARK: - Disambiguation candidate count (kills M11)

    func testThreeWayAmbiguity_offersExactlyThreeCandidates() {
        let kb = makeKB([
            knownIssue("A", ["alpha", "x1"]), knownIssue("B", ["alpha", "x2"]),
            knownIssue("C", ["alpha", "x3"]), knownIssue("D", ["alpha", "x4"])
        ])
        // Each entry hits 1 region ("alpha") → none suggest; four plausible, but
        // the follow-up should offer the top three, not two or four.
        guard case .disambiguate(let candidates) = classifier.classify(userText: "alpha", knowledgeBase: kb).decision else {
            return XCTFail("four one-region matches must disambiguate")
        }
        XCTAssertEqual(candidates.count, 3)
    }

    // MARK: - Version-gate defense in depth (kills M9)

    func testMalformedHowToWithFixVersion_stillSurfacesOnCurrentBuild() {
        // A how_to entry should never be version-gated even if it wrongly carries
        // a fix version — the kind check guards it independently of the schema
        // lint. Remove `resolvedKind == .knownIssue` from the gate and this
        // escalates (the 3.3.0 user "already has" the 3.2.0 fix).
        let malformed = KBEntry(id: "H", category: .other, kind: .howTo, status: .fixedIn,
                                fixedInVersion: "3.2.0", symptomKeywords: ["switch libraries"],
                                userFacingWorkaround: "Tap the Palace logo to switch.",
                                confidenceThreshold: 0.1)
        let current = ContextSnapshot(appVersion: "3.3.0", appBuild: "488", osVersion: "26.4.2",
                                      deviceModel: "iPhone17,2", distributor: "palace_marketplace")
        XCTAssertEqual(
            classifier.classify(userText: "how do I switch libraries", context: current,
                                knowledgeBase: makeKB([malformed])).decision,
            .suggest(entryId: "H")
        )
    }
}
