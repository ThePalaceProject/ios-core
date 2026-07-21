import XCTest
@testable import TriageBotCore

/// Systematic coverage of the two context filters — the version gate and the
/// distributor filter — across EVERY entry that declares them, not a sampled
/// one or two. Each is driven with an ideal input (the entry's own keywords) so
/// only the filter under test decides the outcome.
final class VersionGateMatrixTests: XCTestCase {

    private let classifier = LocalClassifier()

    private func loadEntries() throws -> [KBEntry] {
        try BundledCatalogSource.loadCatalogSync().entries
    }

    private func kb(_ entries: [KBEntry]) -> KnowledgeBase {
        KnowledgeBase(catalog: KBCatalog(version: "matrix", updatedAt: "2026-07-20", entries: entries))
    }

    /// The entry's own keywords, arranged to land at distinct positions.
    private func idealPhrase(_ entry: KBEntry) -> String {
        entry.symptomKeywords.prefix(3).joined(separator: " and ")
    }

    private func context(version: String, distributor: String, auth: String? = nil) -> ContextSnapshot {
        ContextSnapshot(appVersion: version, appBuild: "1", osVersion: "26.4.2",
                        deviceModel: "iPhone17,2", distributor: distributor, authType: auth)
    }

    private func suggests(_ entry: KBEntry, _ result: ClassificationResult) -> Bool {
        if case .suggest(let id) = result.decision { return id == entry.id }
        return false
    }

    // MARK: - Version gate, both directions, for every fixed_in entry

    func testVersionGate_everyFixedInEntry_bothDirections() throws {
        let entries = try loadEntries()
        let knowledgeBase = kb(entries)
        let fixedIn = entries.filter { $0.status == .fixedIn && $0.fixedInVersion != nil }
        XCTAssertFalse(fixedIn.isEmpty, "expected some fixed_in entries to exercise the gate")

        for entry in fixedIn {
            let fixVersion = entry.fixedInVersion!
            let distributor = entry.distributorFilter?.first ?? "palace_marketplace"
            let auth = entry.authTypeFilter?.first
            let phrase = idealPhrase(entry)

            // Below the fix → the patron does NOT have the fix → surface it.
            let below = classifier.classify(userText: phrase, category: entry.category,
                                            context: context(version: "1.0.0", distributor: distributor, auth: auth),
                                            knowledgeBase: knowledgeBase)
            XCTAssertTrue(suggests(entry, below),
                          "\(entry.id): must surface to a patron BELOW its fix version \(fixVersion) (got \(below.decision))")

            // At / past the fix → the patron HAS the fix → suppress (a lingering
            // symptom is a regression that should escalate, not show a stale card).
            let atFix = classifier.classify(userText: phrase, category: entry.category,
                                            context: context(version: fixVersion, distributor: distributor, auth: auth),
                                            knowledgeBase: knowledgeBase)
            XCTAssertFalse(suggests(entry, atFix),
                           "\(entry.id): must be gated away from a patron who already has the \(fixVersion) fix (got \(atFix.decision))")
        }
    }

    // MARK: - Distributor filter, for every entry that declares one

    func testDistributorFilter_everyFilteredEntry_excludedForOtherDistributor() throws {
        let entries = try loadEntries()
        let knowledgeBase = kb(entries)
        let filtered = entries.filter { ($0.distributorFilter?.isEmpty == false) }
        XCTAssertFalse(filtered.isEmpty, "expected some distributor-filtered entries")

        for entry in filtered {
            let phrase = idealPhrase(entry)
            // A distributor that is deliberately NOT in the entry's allow-list.
            let foreign = "distributor_not_in_any_filter"
            XCTAssertFalse(entry.distributorFilter!.contains(foreign))

            let result = classifier.classify(
                userText: phrase, category: entry.category,
                context: context(version: "1.0.0", distributor: foreign, auth: entry.authTypeFilter?.first),
                knowledgeBase: knowledgeBase)
            XCTAssertFalse(suggests(entry, result),
                           "\(entry.id): declares distributor_filter \(entry.distributorFilter!) but was suggested to a '\(foreign)' patron (got \(result.decision))")
        }
    }

    // MARK: - how_to entries are gate-immune even on the newest build

    func testHowToEntries_surfaceOnNewestBuild() throws {
        let entries = try loadEntries()
        let knowledgeBase = kb(entries)
        for entry in entries where entry.resolvedKind == .howTo {
            let result = classifier.classify(
                userText: idealPhrase(entry), category: entry.category,
                context: context(version: "99.0.0", distributor: "palace_marketplace"),
                knowledgeBase: knowledgeBase)
            XCTAssertTrue(suggests(entry, result),
                          "\(entry.id): how_to must surface regardless of build (got \(result.decision))")
        }
    }
}
