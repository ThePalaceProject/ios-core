import XCTest
@testable import TriageBotCore

/// Structural health of every bundled entry's PATRON-FACING contract — the parts
/// a unit test of the classifier never touches: the guided-step flow, telemetry
/// diagnostics, escalation prompts, and whether the entry can be surfaced at all.
/// A malformed entry here renders a broken conversation in production even though
/// the classifier logic is perfect.
final class CatalogContractCompletenessTests: XCTestCase {

    private func loadEntries() throws -> [KBEntry] {
        try BundledCatalogSource.loadCatalogSync().entries
    }

    // MARK: - Guided-step flow is well-formed and terminating

    func testGuidedSteps_areWellFormedAndCanTerminate() throws {
        for entry in try loadEntries() where entry.resolvedKind != .genericFlow {
            guard let steps = entry.userFacingSteps, !steps.isEmpty else { continue }

            // Unique step ids within the entry (routing + telemetry rely on it).
            let stepIds = steps.map { $0.id }
            XCTAssertEqual(stepIds.count, Set(stepIds).count, "\(entry.id): duplicate step ids")

            for step in steps {
                XCTAssertFalse(step.instruction.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(entry.id)/\(step.id): empty instruction")
                XCTAssertFalse(step.check.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(entry.id)/\(step.id): empty check")
                if let responses = step.responses {
                    XCTAssertFalse(responses.isEmpty, "\(entry.id)/\(step.id): responses present but empty")
                    for r in responses {
                        XCTAssertFalse(r.label.trimmingCharacters(in: .whitespaces).isEmpty,
                                       "\(entry.id)/\(step.id): empty response label")
                    }
                }
            }

            // The flow must be able to END: the LAST step must offer at least one
            // terminal outcome (resolved or escalate). If its only outcomes are
            // `advance`, the walker falls off the end with nowhere to go.
            if let last = steps.last, let responses = last.responses {
                let terminal = responses.contains { $0.outcome == .resolved || $0.outcome == .escalate }
                XCTAssertTrue(terminal, "\(entry.id): last step '\(last.id)' has no terminal (resolved/escalate) outcome — the flow can't end")
            }

            // Every step should offer at least one non-`advance` OR a following
            // step to advance to — i.e. no non-terminal step whose only outcome
            // is advance when it IS the last step (covered above), and no step
            // with an empty outcome set.
            for step in steps {
                if let responses = step.responses {
                    XCTAssertTrue(responses.contains { $0.outcome == .resolved || $0.outcome == .escalate }
                                  || step.id != steps.last?.id,
                                  "\(entry.id)/\(step.id): dead-end step")
                }
            }
        }
    }

    // MARK: - Telemetry diagnostics are unique within an entry

    func testDiagnostics_areUniqueWithinEntry() throws {
        for entry in try loadEntries() where entry.resolvedKind != .genericFlow {
            guard let steps = entry.userFacingSteps else { continue }
            var diagnostics: [String] = []
            for step in steps {
                if let d = step.diagnostic { diagnostics.append(d) }
                for r in step.responses ?? [] where r.diagnostic != nil { diagnostics.append(r.diagnostic!) }
            }
            XCTAssertEqual(diagnostics.count, Set(diagnostics).count,
                           "\(entry.id): duplicate telemetry diagnostics — per-step success rates would collide")
        }
    }

    // MARK: - Escalation follow-up prompt is real when present

    func testEscalationFollowUp_hasNonEmptyPrompt() throws {
        for entry in try loadEntries() where entry.resolvedKind != .genericFlow {
            guard let followUp = entry.escalationFollowUp else { continue }
            XCTAssertFalse(followUp.prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(entry.id): escalation follow-up present but prompt is empty")
        }
    }

    // MARK: - Every entry is REACHABLE (its own keywords can surface it)

    /// Every entry a patron can be MATCHED to must be reachable from its own
    /// keywords. `generic_flow` ladders are exempt by design: they carry no
    /// keywords and are offered when nothing matched, so "unreachable by
    /// keywords" is their defining property rather than a defect.
    func testEveryEntry_isSuggestableByItsOwnKeywords() throws {
        let entries = try loadEntries().filter { $0.resolvedKind != .genericFlow }
        let kb = KnowledgeBase(catalog: KBCatalog(version: "reach", updatedAt: "2026-07-20", entries: entries))
        let classifier = LocalClassifier()

        for entry in entries {
            // Build an ideal input: three of the entry's own keywords joined so
            // they land at distinct positions (>= 2 regions for known_issue,
            // >= 1 for how_to), and a context that satisfies its filters and is
            // below any fix version so the gate never hides it.
            let phrase = entry.symptomKeywords.prefix(3).joined(separator: " and ")
            let context = ContextSnapshot(
                appVersion: "1.0.0",
                appBuild: "1",
                osVersion: "26.4.2",
                deviceModel: "iPhone17,2",
                distributor: entry.distributorFilter?.first ?? "palace_marketplace",
                authType: entry.authTypeFilter?.first
            )
            let result = classifier.classify(userText: phrase, category: entry.category, context: context, knowledgeBase: kb)

            let reachable: Bool
            switch result.decision {
            case .suggest(let id): reachable = (id == entry.id)
            case .disambiguate(let ids): reachable = ids.contains(entry.id)
            case .escalate: reachable = false
            }
            XCTAssertTrue(reachable,
                          "\(entry.id) is UNREACHABLE — no input built from its own keywords surfaces it (got \(result.decision)). Its keywords can't form enough distinct regions, or its filters contradict.")
        }
    }
}
