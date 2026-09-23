import XCTest
@testable import TriageBotCore

/// PP-4807 — the ticket preview editor. Proves per-field include/omit toggles
/// and description edits flow through the reducer AND that an omitted field is
/// truly absent from the serialized payload (email body + JSON attachment), not
/// merely hidden in the card. Also pins the barcode's default-omitted + hashed
/// behavior.
final class PreviewEditorTests: XCTestCase {

    private func emptyKBReducer() -> ConversationReducer {
        let catalog = KBCatalog(version: "t", updatedAt: "2026-07-16", entries: [])
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    private func contextWithEverything() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "3.3.0", appBuild: "500", osVersion: "26.4.2", deviceModel: "iPhone17,2",
            libraryName: "Morton Public Library",
            libraryUUID: "anon-abc12345",
            distributor: "palace_marketplace",
            authType: "oauth",
            networkState: "wifi",
            recentLogLines: ["[I] launched app", "[E] fetch failed", "[D] retrying"],
            libraryBarcode: "anon-cardhash"
        )
    }

    private func draftingState(omitted: Set<TicketField> = []) -> ConversationState {
        let draft = TicketDraft(
            userDescription: "original description",
            category: .signin,
            context: contextWithEverything(),
            omittedFields: omitted
        )
        return ConversationState(
            step: .drafting(ticket: draft),
            messages: [.init(sender: .bot, kind: .ticketPreview(draft))]
        )
    }

    private func draftFrom(_ step: ConversationState.Step) -> TicketDraft? {
        if case .drafting(let d) = step { return d }
        return nil
    }

    // MARK: - Per-field toggle

    func testToggleField_addsThenRemovesFromOmittedSet() {
        let reducer = emptyKBReducer()
        let (afterOmit, _) = reducer.reduce(state: draftingState(), action: .userToggledDraftField(.library))
        XCTAssertTrue(draftFrom(afterOmit.step)?.omittedFields.contains(.library) == true,
                      "First toggle must omit the field")

        let (afterInclude, _) = reducer.reduce(state: afterOmit, action: .userToggledDraftField(.library))
        XCTAssertFalse(draftFrom(afterInclude.step)?.omittedFields.contains(.library) == true,
                       "Second toggle must re-include the field")
    }

    func testToggleField_updatesThePreviewMessageInPlace() {
        let reducer = emptyKBReducer()
        let (next, _) = reducer.reduce(state: draftingState(), action: .userToggledDraftField(.network))
        let previews = next.messages.filter { if case .ticketPreview = $0.kind { return true }; return false }
        XCTAssertEqual(previews.count, 1, "Toggling must not duplicate the preview card")
        if case .ticketPreview(let d) = previews.first?.kind {
            XCTAssertTrue(d.omittedFields.contains(.network), "The rendered preview must reflect the toggle")
        } else {
            XCTFail("Expected a ticketPreview message")
        }
    }

    func testToggleField_ignoredOutsideDrafting() {
        let reducer = emptyKBReducer()
        let state = ConversationState(step: .awaitingCategory)
        let (next, effects) = reducer.reduce(state: state, action: .userToggledDraftField(.library))
        XCTAssertEqual(next.step, .awaitingCategory)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Omitted field is ABSENT from the serialized payload

    func testOmittedLibrary_absentFromBodyAndJSON() {
        let reducer = emptyKBReducer()
        let (next, _) = reducer.reduce(state: draftingState(), action: .userToggledDraftField(.library))
        guard let draft = draftFrom(next.step) else { return XCTFail("no draft") }

        let body = TicketEmailComposition.body(for: draft)
        XCTAssertFalse(body.contains("Morton Public Library"), "Omitted library must not appear in the email body")

        let json = jsonAttachmentString(for: draft)
        XCTAssertFalse(json.contains("Morton Public Library"), "Omitted library must be ABSENT from the JSON attachment")
        XCTAssertFalse(json.contains("anon-abc12345"), "Omitted library UUID must be absent too")
    }

    func testOmitLogs_dropsLogContentFromPayload() {
        let reducer = emptyKBReducer()
        let (next, _) = reducer.reduce(state: draftingState(), action: .userOmittedLogs(true))
        guard let draft = draftFrom(next.step) else { return XCTFail("no draft") }

        XCTAssertTrue(draft.omittedFields.contains(.logs))
        let json = jsonAttachmentString(for: draft)
        XCTAssertFalse(json.contains("[E] fetch failed"), "Omitted logs must not appear in the JSON payload")
        // And the logs .txt attachment must not be produced.
        XCTAssertFalse(
            TicketEmailComposition.attachments(for: draft).contains { $0.fileName == "palace-logs.txt" },
            "Omitting logs must drop the log attachment entirely"
        )
    }

    // MARK: - Description editing (redacted, PP-4805 posture)

    func testEditDescription_redactsAndReplacesDescription() {
        let reducer = emptyKBReducer()
        let (next, _) = reducer.reduce(state: draftingState(), action: .userEditedDescription("actually my pin is 4321"))
        guard let draft = draftFrom(next.step) else { return XCTFail("no draft") }
        XCTAssertFalse(draft.userDescription.contains("4321"), "Edited description must be redacted")
        XCTAssertFalse(draft.userDescription.contains("original description"), "Edit must replace the old text")
    }

    // MARK: - Barcode: default omitted, hashed, opt-in

    func testBarcode_defaultOmitted_absentFromPayload_untilIncluded() {
        let reducer = emptyKBReducer()
        // Assemble a real escalation draft so the reducer's default-omit policy runs.
        var state = ConversationState(step: .awaitingDescription(category: .other), context: contextWithEverything())
        (state, _) = reducer.reduce(state: state, action: .inputChanged("something novel"))
        let (drafted, _) = reducer.reduce(state: state, action: .userSubmittedDescription)
        guard let draft = draftFrom(drafted.step) else { return XCTFail("expected drafting, got \(drafted.step)") }

        XCTAssertTrue(draft.omittedFields.contains(.barcode), "Barcode must default to omitted")
        let jsonOmitted = jsonAttachmentString(for: draft)
        XCTAssertFalse(jsonOmitted.contains("anon-cardhash"), "Omitted barcode must be absent from the payload")

        // Opt in.
        let (included, _) = reducer.reduce(state: drafted, action: .userToggledDraftField(.barcode))
        guard let includedDraft = draftFrom(included.step) else { return XCTFail("no draft") }
        let bodyIncluded = TicketEmailComposition.body(for: includedDraft)
        XCTAssertTrue(bodyIncluded.contains("anon-cardhash"), "When opted in, the hashed barcode must be sent")
        // Never the raw card number — only the hash form.
        XCTAssertTrue(includedDraft.context.libraryBarcode?.hasPrefix("anon-") == true)
    }

    // MARK: - Contract snapshot of the payload for three configurations

    func testPayloadContract_allOn_logsOmitted_everythingOmitted() {
        // all-on
        let allOn = TicketDraft(userDescription: "d", category: .signin, context: contextWithEverything(), omittedFields: [])
        let allOnBody = TicketEmailComposition.body(for: allOn)
        XCTAssertTrue(allOnBody.contains("Library: Morton Public Library"))
        XCTAssertTrue(allOnBody.contains("Network: wifi"))
        XCTAssertTrue(allOnBody.contains("Library card (hashed): anon-cardhash"))
        XCTAssertTrue(TicketEmailComposition.attachments(for: allOn).contains { $0.fileName == "palace-logs.txt" })

        // logs-omitted (everything else on)
        let logsOff = allOn.withOmittedFields([.logs])
        let logsOffBody = TicketEmailComposition.body(for: logsOff)
        XCTAssertTrue(logsOffBody.contains("Library: Morton Public Library"))
        XCTAssertFalse(TicketEmailComposition.attachments(for: logsOff).contains { $0.fileName == "palace-logs.txt" })

        // everything-omittable off
        let allOff = allOn.withOmittedFields(Set(TicketField.allCases))
        let allOffBody = TicketEmailComposition.body(for: allOff)
        XCTAssertFalse(allOffBody.contains("Morton Public Library"))
        XCTAssertFalse(allOffBody.contains("Network: wifi"))
        XCTAssertFalse(allOffBody.contains("anon-cardhash"))
        XCTAssertFalse(allOffBody.contains("Distributor: palace_marketplace"))
        // Core fields still present — the ticket stays actionable.
        XCTAssertTrue(allOffBody.contains("App: 3.3.0 (500)"))
        XCTAssertTrue(allOffBody.contains("Device: iPhone17,2"))
    }

    // MARK: - Helpers

    private func jsonAttachmentString(for draft: TicketDraft) -> String {
        let attachments = TicketEmailComposition.attachments(for: draft)
        guard let data = attachments.first(where: { $0.fileName == "palace-diagnostics.json" })?.data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
