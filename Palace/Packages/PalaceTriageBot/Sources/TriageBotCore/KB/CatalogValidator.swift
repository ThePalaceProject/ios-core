import Foundation

/// Structural rules a catalog must satisfy before the bot will speak from it.
///
/// This runs at LOAD, not only in tests, because the catalog is designed to be
/// server-supplied for hot updates. A rule enforced only by the test suite is a
/// rule the shipped app does not have: a hot-pushed catalog could tell every
/// sign-in patron to sign out, and nothing on the device would object.
///
/// Scope is deliberately narrow — these are safety invariants about REMEDY
/// LADDERS, where being wrong costs the patron something concrete. Schema shape,
/// keyword strength and copy quality stay in `CatalogSchemaLintTests`, which runs
/// against the bundled file at build time and can afford to be stricter than
/// anything we would enforce against a live catalog.
public enum CatalogValidator {

    /// Per-category remedies that evidence says must never be offered.
    ///
    /// Derived from 204 authoring tickets, using a pre-registered threshold
    /// rather than per-cell judgement: suppress only where the category has at
    /// least 15 resolved tickets AND the remedy was prescribed in at most 3% of
    /// them. Categories below that count (reader, n=4) are UNKNOWN, not zero, and
    /// are governed by the default order instead.
    ///
    ///   sign-in, n=41 — update-the-app prescribed 0 times, sign-out once.
    ///   The two cheapest remedies are the two least applicable in the largest
    ///   category, which is precisely the ordering a cost-only ladder would have
    ///   produced. That is why this table exists.
    static let suppressed: [KBCategory: Set<Remedy>] = [
        .signin: [.updateApp, .signOutIn],
        .audiobook: [.switchLibrary],
        .download: [.switchLibrary],
        .other: [.switchLibrary],
    ]

    /// At most this many rungs in a ladder. The quarter of patrons whose problem
    /// only staff or their library can resolve pay the entire ladder as delay
    /// before reaching a human; three cheap steps is a defensible tax, six is not.
    static let maxRungs = 3

    public static func violations(in catalog: KBCatalog) -> [String] {
        var problems: [String] = []

        for entry in catalog.entries where entry.resolvedKind == .genericFlow {
            let steps = entry.userFacingSteps ?? []

            if steps.isEmpty {
                problems.append("\(entry.id): a ladder with no rungs offers nothing")
            }
            if steps.count > maxRungs {
                problems.append("\(entry.id): \(steps.count) rungs exceeds the limit of \(maxRungs)")
            }
            if !entry.symptomKeywords.isEmpty {
                problems.append("\(entry.id): a ladder must not claim symptoms — it is offered when nothing matched")
            }

            let banned = suppressed[entry.category] ?? []
            for step in steps {
                guard let remedy = step.remedy else { continue }

                if banned.contains(remedy) {
                    problems.append(
                        "\(entry.id)/\(step.id): \(remedy.rawValue) is suppressed for \(entry.category.rawValue) — support prescribed it for this category in ≤3% of resolved tickets")
                }

                if remedy.costTier == .destructive {
                    // Never first: a ladder must not open by destroying content.
                    if step.id == steps.first?.id {
                        problems.append(
                            "\(entry.id)/\(step.id): \(remedy.rawValue) destroys downloaded content and must not be the first rung")
                    }
                    // Always refusable. `responses` nil means the UI renders the
                    // legacy yes/no pair, where "no" advances — which is a way
                    // out — so only an explicit response set that offers no
                    // advance/escalate route is a trap.
                    if let responses = step.responses,
                       !responses.contains(where: { $0.outcome == .advance || $0.outcome == .escalate }) {
                        problems.append(
                            "\(entry.id)/\(step.id): \(remedy.rawValue) is destructive and must remain refusable — no response advances or escalates")
                    }
                }
            }
        }
        return problems
    }
}
