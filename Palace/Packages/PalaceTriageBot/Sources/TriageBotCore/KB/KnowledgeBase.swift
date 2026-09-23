import Foundation

/// Indexed wrapper around a KBCatalog. Built once per chat session from the
/// loaded catalog; the classifier asks it for candidates by category and the
/// reducer asks it for a single entry by id.
public struct KnowledgeBase: Sendable {
    public let catalog: KBCatalog
    /// Ladder rules the loaded catalog broke. Non-empty means the offending
    /// ladders were dropped rather than spoken from — see `init`.
    let validationViolations: [String]

    public init(catalog: KBCatalog) {
        // Validate at LOAD, and degrade rather than refuse. A catalog that
        // violates a ladder rule is not wholly untrustworthy — its entries and
        // answers are still good — so the safe response is to drop the offending
        // LADDERS and keep everything else. The bot then behaves as it did before
        // ladders existed for those categories, which is a known-good state.
        //
        // Enforced here rather than only in tests because this schema is designed
        // to be server-supplied later: a rule that lives only in the test suite is
        // a rule the shipped app does not have.
        let violations = CatalogValidator.violations(in: catalog)
        self.validationViolations = violations

        if violations.isEmpty {
            self.catalog = catalog
        } else {
            let offending = Set(violations.compactMap { $0.split(separator: ":").first.map(String.init) }
                                          .map { $0.split(separator: "/").first.map(String.init) ?? $0 })
            self.catalog = KBCatalog(
                version: catalog.version,
                updatedAt: catalog.updatedAt,
                entries: catalog.entries.filter { !offending.contains($0.id) },
                categoryFollowUps: catalog.categoryFollowUps,
                latestKnownAppVersion: catalog.latestKnownAppVersion
            )
        }
    }

    /// The catch-all question for a category, used when no entry was recognized.
    func categoryFollowUp(for category: KBCategory?) -> KBEscalationFollowUp? {
        guard let category else { return nil }
        return catalog.categoryFollowUps?[category.rawValue]
    }

    /// The remedy ladder for a category, if the catalog defines one.
    func genericFlow(for category: KBCategory?) -> KBEntry? {
        guard let category else { return nil }
        return catalog.entries.first {
            $0.resolvedKind == .genericFlow && $0.category == category
                && !($0.userFacingSteps ?? []).isEmpty
        }
    }

    public func entry(id: String) -> KBEntry? {
        catalog.entries.first { $0.id == id }
    }

    /// Everything a patron who picked `category` should be matched against:
    /// that category's entries, PLUS every how-to regardless of category.
    ///
    /// The topic chip is evidence about a SYMPTOM ("my audiobook won't play" →
    /// Audiobook), and scoping known issues to it is what stops a PDF workaround
    /// reaching an audiobook patron. A how-to is not a symptom: "how do I renew
    /// my loan?" is not a Library question or an Other question, and the category
    /// the catalog assigns a how-to (renewals→other, switch-library→library) is
    /// filing metadata about the answer, not a claim about how the question gets
    /// asked. Scoping them made each answer reachable from exactly one of six
    /// chips, and left the category's known issues to win a how-to question by
    /// default — see `HowToCategoryAgnosticTests` for the measured misroute.
    ///
    /// Deliberately asymmetric: how-tos widen, known issues do not. A blanket
    /// cross-category fallback was the alternative and is unsafe, because
    /// decisive phrases collide across areas ("won't open" belongs to the LCP
    /// PDF entry but is a perfectly natural thing to say about an audiobook).
    func entries(matchableFrom category: KBCategory) -> [KBEntry] {
        catalog.entries.filter { entry in
            guard entry.status != .duplicateOf else { return false }
            return entry.category == category || entry.resolvedKind == .howTo
        }
    }

    /// Entries whose filters allow this context. Used by the classifier to
    /// narrow before keyword scoring — e.g. KI-001 only applies to
    /// palace_marketplace distributors.
    public func entries(matching context: ContextSnapshot?) -> [KBEntry] {
        catalog.entries.filter { entry in
            passesFilters(entry: entry, context: context)
        }
    }

    private func passesFilters(entry: KBEntry, context: ContextSnapshot?) -> Bool {
        if let distributors = entry.distributorFilter,
           let actual = context?.distributor,
           !distributors.contains(actual) {
            return false
        }
        if let authTypes = entry.authTypeFilter,
           let actual = context?.authType,
           !authTypes.contains(actual) {
            return false
        }
        return true
    }
}

/// Loads the bundled catalog.json shipped inside TriageBotCore's resources.
/// Server-backed source can implement the same protocol later for hot updates.
public struct BundledCatalogSource: KnowledgeBaseSource {
    public init() {}

    public func loadCatalog() async throws -> KBCatalog {
        try Self.loadCatalogSync()
    }

    /// Synchronous variant for callers that don't want to bridge async →
    /// sync with a semaphore (which triggers iOS 26's "Hang Risk" runtime
    /// warning per chaos-qa F-004). The underlying work — read the bundled
    /// JSON file, decode — is genuinely synchronous; the async signature
    /// exists for protocol conformance and future server-backed sources.
    public static func loadCatalogSync() throws -> KBCatalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            throw KBLoadError.catalogNotFound
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(KBCatalog.self, from: data)
    }
}

public enum KBLoadError: Error, Equatable {
    case catalogNotFound
    case decodingFailed(String)
}

/// In-memory KnowledgeBaseSource for tests — feed a synthetic catalog without
/// touching disk.
public struct InMemoryCatalogSource: KnowledgeBaseSource {
    public let catalog: KBCatalog

    public init(catalog: KBCatalog) {
        self.catalog = catalog
    }

    public func loadCatalog() async throws -> KBCatalog {
        catalog
    }
}
