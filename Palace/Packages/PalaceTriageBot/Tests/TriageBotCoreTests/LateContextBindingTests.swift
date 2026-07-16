import XCTest
@testable import TriageBotCore

/// PP-4811 — the context-capture race. The async `.captureContext` effect can
/// return AFTER the patron has already raced ahead to a ticket draft (they tap
/// a category, type, and escalate faster than OSLog/AVAudioSession answer). When
/// that happens the draft was assembled with the all-"unknown" placeholder
/// context, and without late-binding the ticket would ship to support with an
/// empty environment — no app version, no OS, no logs. These tests pin that a
/// late `.contextLoaded` binds the real context into an in-flight placeholder
/// draft, and — critically — that it never clobbers a draft that already holds
/// a real, patron-reviewed context.
final class LateContextBindingTests: XCTestCase {

    private func makeReducer() -> ConversationReducer {
        let catalog = KBCatalog(version: "t", updatedAt: "2026-07-16", entries: [])
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    /// Mirrors the reducer's `emptyContext()` — the placeholder synthesized when
    /// a draft is assembled before context has loaded.
    private func placeholderContext() -> ContextSnapshot {
        ContextSnapshot(appVersion: "unknown", appBuild: "unknown",
                        osVersion: "unknown", deviceModel: "unknown")
    }

    private func realContext(barcode: String? = nil) -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2",
            deviceModel: "iPhone17,2", distributor: "palace_marketplace",
            libraryBarcode: barcode
        )
    }

    private func draftingState(context: ContextSnapshot,
                               omitted: Set<TicketField> = []) -> ConversationState {
        let draft = TicketDraft(
            userDescription: "app crashes on open", category: .other,
            context: context, omittedFields: omitted
        )
        return ConversationState(
            step: .drafting(ticket: draft),
            messages: [.init(sender: .bot, kind: .ticketPreview(draft))]
        )
    }

    private func draft(from step: ConversationState.Step) -> TicketDraft? {
        switch step {
        case .drafting(let d), .submitting(let d): return d
        case .awaitingEscalationFollowUp(_, let d): return d
        default: return nil
        }
    }

    // MARK: - Late bind into a placeholder draft

    func testLateContext_whileDraftingWithPlaceholder_bindsRealContextIntoDraft() {
        let reducer = makeReducer()
        let state = draftingState(context: placeholderContext())
        XCTAssertTrue(draft(from: state.step)?.context.isPlaceholder == true,
                      "Precondition: draft starts with the placeholder context")

        let (next, _) = reducer.reduce(state: state, action: .contextLoaded(realContext()))

        let bound = draft(from: next.step)
        XCTAssertEqual(bound?.context.appVersion, "3.3.0",
                       "The real app version must be bound into the in-flight draft")
        XCTAssertEqual(bound?.context.osVersion, "26.4.2")
        XCTAssertFalse(bound?.context.isPlaceholder ?? true,
                       "The draft must no longer carry the empty placeholder context")
    }

    func testLateContext_reboundDraft_updatesThePreviewMessageInPlace() {
        let reducer = makeReducer()
        let state = draftingState(context: placeholderContext())

        let (next, _) = reducer.reduce(state: state, action: .contextLoaded(realContext()))

        let previews = next.messages.filter {
            if case .ticketPreview = $0.kind { return true }; return false
        }
        XCTAssertEqual(previews.count, 1, "Rebind must not duplicate the preview card")
        if case .ticketPreview(let d) = previews.first?.kind {
            XCTAssertEqual(d.context.appVersion, "3.3.0",
                           "The rendered preview must show the newly-bound real context")
        } else {
            XCTFail("Expected a ticketPreview message")
        }
    }

    // MARK: - Never clobber a real, patron-reviewed context

    func testLateContext_whileDraftingWithRealContext_doesNotClobberTheDraft() {
        let reducer = makeReducer()
        // A restored/pre-loaded draft already holding a real context the patron
        // may have reviewed. A late duplicate capture must NOT overwrite it.
        let original = realContext()
        let state = draftingState(context: original)

        let laterDifferent = ContextSnapshot(
            appVersion: "9.9.9", appBuild: "999", osVersion: "1.0",
            deviceModel: "iPhoneXX", distributor: "palace_marketplace"
        )
        let (next, _) = reducer.reduce(state: state, action: .contextLoaded(laterDifferent))

        XCTAssertEqual(draft(from: next.step)?.context.appVersion, "3.3.0",
                       "A draft with a real context must be left untouched by a late capture")
    }

    // MARK: - Barcode default-omit is re-applied on rebind

    func testLateContext_withBarcode_defaultOmitsBarcodeInReboundDraft() {
        let reducer = makeReducer()
        // Placeholder draft has no barcode yet, so barcode is not omitted.
        let state = draftingState(context: placeholderContext(), omitted: [])

        let (next, _) = reducer.reduce(
            state: state, action: .contextLoaded(realContext(barcode: "anon-cardhash"))
        )

        XCTAssertTrue(draft(from: next.step)?.omittedFields.contains(.barcode) == true,
                      "A barcode arriving via late context must default to omitted (opt-in), " +
                      "not silently ship in the ticket")
    }

    func testLateContext_withBarcode_preservesPreExistingOmissions() {
        let reducer = makeReducer()
        // Patron had already omitted logs on the placeholder draft.
        let state = draftingState(context: placeholderContext(), omitted: [.logs])

        let (next, _) = reducer.reduce(
            state: state, action: .contextLoaded(realContext(barcode: "anon-cardhash"))
        )

        let omitted = draft(from: next.step)?.omittedFields ?? []
        XCTAssertTrue(omitted.contains(.logs), "The patron's prior omission must survive the rebind")
        XCTAssertTrue(omitted.contains(.barcode), "The new barcode default-omit must be added on top")
    }

    // MARK: - Other in-flight steps

    func testLateContext_whileSubmitting_bindsRealContext() {
        let reducer = makeReducer()
        let placeholderDraft = TicketDraft(
            userDescription: "x", category: .other, context: placeholderContext()
        )
        let state = ConversationState(step: .submitting(ticket: placeholderDraft))

        let (next, _) = reducer.reduce(state: state, action: .contextLoaded(realContext()))

        if case .submitting(let d) = next.step {
            XCTAssertFalse(d.context.isPlaceholder,
                           "A ticket already submitting with a placeholder must still get the real context bound")
        } else {
            XCTFail("Expected to remain in .submitting")
        }
    }

    // MARK: - emptyContext() placeholder invariant (guards late-bind)

    func testEmptyContext_readsAsPlaceholder_andRealContextDoesNot() {
        // Late-bind hinges on emptyContext().isPlaceholder == true. Drive the
        // reducer to escalate a description with NO context loaded, so the draft
        // is assembled from the REAL emptyContext() (not this file's mirror), and
        // pin the invariant. A future edit to emptyContext() that breaks it — or
        // an isPlaceholder that stops recognizing it — fails here.
        let reducer = makeReducer()
        var state = ConversationState(step: .awaitingDescription(category: .other))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("app crashes on open"))
        let (next, _) = reducer.reduce(state: state, action: .userSubmittedDescription)

        XCTAssertTrue(draft(from: next.step)?.context.isPlaceholder == true,
                      "The reducer's real emptyContext() must read as a placeholder")
        XCTAssertFalse(realContext().isPlaceholder,
                       "A populated context must NOT read as a placeholder, or late-bind clobbers real data")
    }

    // MARK: - The common case: context arrives before any draft exists

    func testLateContext_whenNotYetDrafting_justStoresContextWithoutError() {
        let reducer = makeReducer()
        let state = ConversationState(step: .awaitingCategory)

        let (next, _) = reducer.reduce(state: state, action: .contextLoaded(realContext()))

        XCTAssertEqual(next.context?.appVersion, "3.3.0",
                       "Normal ordering: context is stored for the draft that comes later")
        XCTAssertEqual(next.step, .awaitingCategory, "No draft yet, so the step is unchanged")
    }
}
