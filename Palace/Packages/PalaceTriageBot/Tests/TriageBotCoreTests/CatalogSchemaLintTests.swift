import XCTest
@testable import TriageBotCore

/// Structural invariants on the bundled catalog. These are cheap guards that
/// pin the data contradictions PP-4825 fixed so they can't silently return —
/// e.g. KI-001 once carried status:open AND fixed_in_version:3.2.0, which made
/// the gate show a "fix shipping next release" card to patrons who already had
/// the fix.
final class CatalogSchemaLintTests: XCTestCase {

    private func loadEntries() throws -> [KBEntry] {
        try BundledCatalogSource.loadCatalogSync().entries
    }

    /// A fix version only makes sense on a `fixed_in` entry — that's the pair the
    /// version gate reads. Any other status carrying a fix version is the KI-001
    /// contradiction.
    func testFixVersionImpliesFixedInStatus() throws {
        for entry in try loadEntries() where entry.fixedInVersion != nil {
            XCTAssertEqual(
                entry.status, .fixedIn,
                "\(entry.id): has fixed_in_version=\(entry.fixedInVersion!) but status=\(String(describing: entry.status)). A fix version must pair with status:fixed_in or the gate misbehaves."
            )
        }
    }

    /// how_to keywords MUST be multi-word intent phrases. A bare word like
    /// "renew" fires on "renewed my card" (a live false positive we fixed) —
    /// because how_to suggests at a single distinct region, one generic word is
    /// enough to misroute. Multi-word phrases keep the single-region floor safe.
    func testHowToKeywordsAreMultiWord() throws {
        var offenders: [String] = []
        for entry in try loadEntries() where entry.resolvedKind == .howTo {
            for keyword in entry.symptomKeywords where !keyword.contains(" ") {
                offenders.append("\(entry.id): '\(keyword)'")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "how_to keywords must be multi-word intent phrases, not single words: \(offenders)")
    }

    /// Generic symptom words are corroborating evidence, never strong evidence.
    ///
    /// `symptom_keywords` is the sufficient-alone list: one match there is grounds
    /// to offer the entry's workaround. A word like "stuck" or "crashes" describes
    /// half the app, so if it sits in that list the bot will hand a patron a
    /// specific bug's fix on the strength of one generic word — the chaos-qa F-002
    /// defect. Such words belong in `corroborating_keywords`, where they sharpen a
    /// real match without ever being one.
    ///
    /// This is the guard that lets the classifier gate on evidence STRENGTH rather
    /// than evidence COUNT. Without it, the partition would drift the first time
    /// someone adds a keyword to fix a missed ticket, and the ≥1-strong-region
    /// floor would quietly become as unsafe as the ≥2-of-anything floor it
    /// replaced.
    func testGenericSymptomWordsAreNotStrongEvidence() throws {
        // Bare words that describe a symptom without identifying a cause. Each one
        // appears verbatim in the shipped catalog, on entries whose actual bug is
        // far narrower than the word.
        let generic: Set<String> = [
            "stuck", "crashes", "crashed", "crash", "hangs", "hang", "hanging",
            "spinning", "spinner", "blinks", "blinking", "frozen", "freezes",
            "download", "downloads", "downloading", "bookshelf", "boxes",
            "placeholder", "reinstall", "broken", "error", "failed", "failing",
            "slow", "buggy", "glitch", "weird", "wrong"
        ]

        var offenders: [String] = []
        for entry in try loadEntries() {
            for keyword in entry.symptomKeywords
            where generic.contains(keyword.lowercased().trimmingCharacters(in: .whitespaces)) {
                offenders.append("\(entry.id): '\(keyword)'")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            generic symptom words found in symptom_keywords (the sufficient-alone list). \
            Move them to corroborating_keywords — as strong evidence they let one \
            vague word route a patron to a specific bug's workaround: \(offenders)
            """
        )
    }

    /// A word cannot be both sufficient-alone and corroborating. Overlap would make
    /// the strength partition meaningless — the strong list would win and the weak
    /// listing would read as a guard that isn't there.
    func testStrengthTiersDoNotOverlap() throws {
        for entry in try loadEntries() {
            let strong = Set(entry.symptomKeywords.map { $0.lowercased() })
            let weak = Set((entry.corroboratingKeywords ?? []).map { $0.lowercased() })
            XCTAssertTrue(
                strong.isDisjoint(with: weak),
                "\(entry.id): keywords in both tiers: \(strong.intersection(weak).sorted())"
            )
        }
    }

    /// `confidence_threshold` must not read as a safety knob it is not.
    ///
    /// Scores are (strong + 0.5·weak) / 3. The weakest non-zero score any input
    /// can produce is a single corroborating region: 1/6 ≈ 0.167. Every threshold
    /// in the shipped catalog is 0.08–0.1, so every one of them passes
    /// unconditionally — the suggest gate is carried entirely by the
    /// strong-evidence requirement and the margin guards.
    ///
    /// That is fine as long as it is DELIBERATE. This test pins the two states
    /// apart: a threshold below the floor is an explicit no-op, and anything at or
    /// above it is a real constraint that must be chosen against the current
    /// scale, not inherited from the old quantized one where 0.5 meant "two
    /// regions". Raising a value without reading this is how a knob that never
    /// fired starts silently suppressing matches.
    func testConfidenceThresholdsAreDeliberate() throws {
        let weakestPossibleScore = 0.5 / 3.0   // one corroborating region
        var active: [String] = []
        for entry in try loadEntries() where entry.confidenceThreshold >= weakestPossibleScore {
            let impliedStrongRegions = Int((entry.confidenceThreshold * 3.0).rounded(.up))
            active.append("\(entry.id): \(entry.confidenceThreshold) demands ~\(impliedStrongRegions) strong region(s)")
        }
        XCTAssertTrue(
            active.isEmpty,
            """
            these thresholds now constrain matching on the CURRENT score scale.             Confirm each was chosen against (strong + 0.5·weak)/3 rather than the             retired {1/3, 2/3, 1} quantization, then add it to this test's             allowance: \(active)
            """
        )
    }

    /// Duplicate entry ids silently break `entry(id:)` lookups and telemetry.
    func testEntryIdsAreUnique() throws {
        let ids = try loadEntries().map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "catalog has duplicate entry ids")
    }

    /// how_to (general-help) entries are not bugs: no known-issue status, no fix
    /// version, no version gate. known_issue entries must carry a status.
    func testKindShapeInvariants() throws {
        for entry in try loadEntries() {
            switch entry.resolvedKind {
            case .howTo:
                XCTAssertNil(entry.status, "\(entry.id): how_to entry must not carry a known-issue status")
                XCTAssertNil(entry.fixedInVersion, "\(entry.id): how_to entry must not carry a fix version")
            case .knownIssue:
                XCTAssertNotNil(entry.status, "\(entry.id): known_issue entry must declare a status")
            case .genericFlow:
                // A ladder is not a diagnosis: no known-issue status, no version
                // gate, and it must carry rungs or it has nothing to offer.
                XCTAssertNil(entry.status, "\(entry.id): generic_flow must not carry a known-issue status")
                XCTAssertNil(entry.fixedInVersion, "\(entry.id): generic_flow must not carry a fix version")
                XCTAssertFalse((entry.userFacingSteps ?? []).isEmpty,
                               "\(entry.id): generic_flow with no steps offers nothing")
                XCTAssertTrue(entry.symptomKeywords.isEmpty,
                              "\(entry.id): a ladder must not claim symptoms — it is offered when nothing matched")
            }
        }
    }

    /// Distinct-region scoring made nested keyword variants within one entry dead
    /// weight (they collapse to a single region). Flagging them keeps the corpus
    /// honest about how many DISTINCT concepts an entry actually keys on.
    func testNoNestedKeywordVariantsWithinAnEntry() throws {
        var offenders: [String] = []
        for entry in try loadEntries() {
            let keywords = entry.symptomKeywords.map { TextNormalizer.normalize($0) }
            for (i, a) in keywords.enumerated() {
                for (j, b) in keywords.enumerated() where i != j {
                    // a is a strict substring of b → nested; a is redundant.
                    if a != b, b.contains(a) {
                        offenders.append("\(entry.id): '\(a)' is nested inside '\(b)'")
                    }
                }
            }
        }
        // Empty, and deliberately so. This set used to grandfather 5 bare-"download"
        // nestings in KI-008: under the old count-based floor a known-issue entry
        // needed TWO distinct regions to suggest, so bare "download" was kept as
        // load-bearing padding — it supplied the second region alongside "never
        // works" on inputs like "trying to download an ebook and it never works".
        //
        // Keyword strength tiers removed the need for that padding: "never works"
        // is strong evidence and now suffices alone, so "download" moved to
        // `corroborating_keywords` where a bare category noun belongs. The
        // exception retired with the floor that forced it.
        //
        // Asserting the exact SET (not a count ≤ N) means a swap — one nesting
        // fixed, a new one introduced — still fails.
        let allowed: Set<String> = []
        if Set(offenders) != allowed {
            for o in offenders where !allowed.contains(o) { print("  UNEXPECTED NESTED-KEYWORD: \(o)") }
        }
        XCTAssertEqual(Set(offenders), allowed,
                       "Nested-keyword set changed. New entries must use distinct concepts, not nested synonyms; only the KI-008 bare-'download' set is grandfathered.")
    }
}
