import XCTest
@testable import TriageBotCore

final class ConversationReducerTests: XCTestCase {
    private func makeReducer(_ entries: [KBEntry] = .demoEntries) -> ConversationReducer {
        let catalog = KBCatalog(version: "test", updatedAt: "2026-05-28", entries: entries)
        return ConversationReducer(knowledgeBase: KnowledgeBase(catalog: catalog))
    }

    // MARK: - Start

    func testStart_transitionsToAwaitingCategory_andRequestsContextCapture() {
        let reducer = makeReducer()
        let (state, effects) = reducer.reduce(state: ConversationState(), action: .start)

        XCTAssertEqual(state.step, .awaitingCategory)
        XCTAssertEqual(state.messages.count, 2, "Welcome text + category chips")
        XCTAssertTrue(effects.contains(.captureContext))
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let event) = effect { return event.name == "triage_chat_opened" }
            return false
        })
    }

    // MARK: - Category → description → match (round-trip happy path)

    func testFullFlow_audiobookFirstOpenHang_resultsInMatch() {
        let reducer = makeReducer()
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)

        // Ensure context is loaded so distributor filter passes
        let context = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            distributor: "palace_marketplace"
        )
        (state, _) = reducer.reduce(state: state, action: .contextLoaded(context))
        XCTAssertNotNil(state.context, "Context must be persisted in state")

        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.audiobook))
        XCTAssertEqual(state.step, .awaitingDescription(category: .audiobook))

        (state, _) = reducer.reduce(state: state, action: .inputChanged("my audiobook keeps spinning and won't play the first time I open it"))
        let (finalState, effects) = reducer.reduce(state: state, action: .userSubmittedDescription)

        guard case .matched(let entryId) = finalState.step else {
            return XCTFail("Expected .matched, got \(finalState.step)")
        }
        XCTAssertEqual(entryId, "KI-2026-001-audiobook-first-open-hang")
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let event) = effect { return event.name == "triage_kb_match" }
            return false
        })
        XCTAssertTrue(finalState.messages.contains { msg in
            if case .kbMatch(let id) = msg.kind { return id == entryId }
            return false
        }, "Last bot message must carry the kbMatch")
    }

    // MARK: - Match → "Notify me when fixed" (round-trip)

    func testMatched_notifyMe_endsConversationCleanly() {
        let reducer = makeReducer()
        var state = ConversationState(step: .matched(entryId: "KI-2026-001-audiobook-first-open-hang"))

        let (next, effects) = reducer.reduce(
            state: state,
            action: .userTappedNotifyMeOnFix(entryId: "KI-2026-001-audiobook-first-open-hang")
        )
        _ = state

        guard case .sent(let receipt) = next.step else {
            return XCTFail("Expected .sent, got \(next.step)")
        }
        XCTAssertEqual(receipt.ticketId, "notify-KI-2026-001-audiobook-first-open-hang")
        XCTAssertTrue(effects.contains { effect in
            if case .emitTelemetry(let event) = effect { return event.name == "triage_user_notify_me" }
            return false
        })
    }

    // MARK: - Match → "File ticket anyway" (round-trip)

    func testMatched_fileTicketAnyway_transitionsToDrafting_withLowPriority() {
        let reducer = makeReducer()
        let context = ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2", deviceModel: "iPhone17,2",
            distributor: "palace_marketplace"
        )
        var state = ConversationState(
            step: .matched(entryId: "KI-2026-001-audiobook-first-open-hang"),
            messages: [.init(sender: .user, kind: .text("audiobook won't play"))],
            context: context
        )

        let (next, _) = reducer.reduce(state: state, action: .userTappedFileTicketAnyway)
        _ = state

        guard case .drafting(let draft) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertEqual(draft.priority, .low, "User-requested follow-up on a known issue should be low-priority")
        XCTAssertEqual(draft.matchedEntryId, "KI-2026-001-audiobook-first-open-hang")
        XCTAssertTrue(draft.helpspotTags.contains("user-requested-followup"))
    }

    // MARK: - Escalate (novel) → confirm submit → receipt (full round-trip)

    func testEscalate_thenConfirmSubmit_emitsSubmitEffect_thenReceiptUpdatesState() {
        let reducer = makeReducer()
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        (state, _) = reducer.reduce(state: state, action: .contextLoaded(ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2", deviceModel: "iPhone17,2"
        )))
        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.reader))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("my font size resets to defaults every time I open an EPUB"))
        let (drafted, _) = reducer.reduce(state: state, action: .userSubmittedDescription)
        state = drafted

        guard case .drafting(let draft) = state.step else {
            return XCTFail("Expected drafting after novel symptom, got \(state.step)")
        }
        XCTAssertNil(draft.matchedEntryId, "Novel symptom must not pin a matched entry")

        // PP-4843: a reducer-driven preview arrives with the send-consent gate
        // armed. The patron seeing the card (its onAppear) dispatches
        // .ticketPreviewPresented, which releases the gate so a deliberate Send
        // is honored. Without this the confirm below would be treated as a
        // same-burst rapid double-tap and suppressed.
        (state, _) = reducer.reduce(state: state, action: .ticketPreviewPresented)

        let (submitting, effects) = reducer.reduce(state: state, action: .userConfirmedTicketSubmit)
        state = submitting

        guard case .submitting = state.step else {
            return XCTFail("Expected .submitting, got \(state.step)")
        }
        XCTAssertTrue(effects.contains { effect in
            if case .submitTicket = effect { return true }
            return false
        }, "Submit must produce a submitTicket effect for the host to execute")

        let receipt = TicketReceipt(ticketId: "HS-99999")
        let (afterReceipt, _) = reducer.reduce(state: state, action: .ticketSubmitted(receipt))

        guard case .sent(let stored) = afterReceipt.step else {
            return XCTFail("Expected .sent after ticketSubmitted, got \(afterReceipt.step)")
        }
        XCTAssertEqual(stored.ticketId, "HS-99999")
    }

    // MARK: - PP-4843 send-consent gate (chaos rapid-tap on Send)

    /// Chaos PP-4843 (MAJOR): on a short conversation the preview's own Send
    /// button renders where the message Send arrow was, so a rapid tap burst
    /// (tap #1 submits the message, tap #2 lands on the just-appeared confirm)
    /// filed a ticket the patron never saw. The reducer arms a send-consent
    /// gate on the fresh preview; a confirm that arrives in the SAME burst —
    /// with no intervening .ticketPreviewPresented — must be a no-op that
    /// leaves the patron on the preview, NOT sent.
    func testRapidSubmitThenConfirm_inSameBurst_staysOnPreview_doesNotFileTicket_PP4843() {
        let reducer = makeReducer()
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        (state, _) = reducer.reduce(state: state, action: .contextLoaded(ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2", deviceModel: "iPhone17,2"
        )))
        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.reader))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("something the knowledge base has never encountered before"))

        // Tap #1 — the message submit. A novel symptom escalates straight to the
        // preview (no matched entry, no follow-up), arming the consent gate.
        let (drafted, _) = reducer.reduce(state: state, action: .userSubmittedDescription)
        guard case .drafting = drafted.step else {
            return XCTFail("Novel symptom should land on the ticket preview, got \(drafted.step)")
        }
        XCTAssertTrue(drafted.pendingSendConsent, "A fresh reducer-driven preview must arm the send-consent gate")

        // Tap #2 — same burst, lands on the confirm button before the patron saw it.
        let (afterRapidConfirm, effects) = reducer.reduce(state: drafted, action: .userConfirmedTicketSubmit)

        guard case .drafting = afterRapidConfirm.step else {
            return XCTFail("A same-burst rapid confirm must NOT leave the preview; got \(afterRapidConfirm.step)")
        }
        XCTAssertFalse(
            effects.contains { if case .submitTicket = $0 { return true }; return false },
            "A rapid confirm the patron never consented to must not file a ticket"
        )
        XCTAssertTrue(
            afterRapidConfirm.messages.contains { if case .ticketPreview = $0.kind { return true }; return false },
            "The preview card must remain so the patron can actually review it"
        )
    }

    /// PP-4843 regression / positive path: once the patron has actually seen the
    /// preview (the card's onAppear dispatches .ticketPreviewPresented, clearing
    /// the gate), a deliberate Send must file the ticket normally.
    func testSubmit_thenPreviewPresented_thenDeliberateConfirm_filesTicket_PP4843() {
        let reducer = makeReducer()
        var (state, _) = reducer.reduce(state: ConversationState(), action: .start)
        (state, _) = reducer.reduce(state: state, action: .contextLoaded(ContextSnapshot(
            appVersion: "3.0.3", appBuild: "478", osVersion: "26.4.2", deviceModel: "iPhone17,2"
        )))
        (state, _) = reducer.reduce(state: state, action: .userTappedCategory(.reader))
        (state, _) = reducer.reduce(state: state, action: .inputChanged("something the knowledge base has never encountered before"))
        (state, _) = reducer.reduce(state: state, action: .userSubmittedDescription)
        guard case .drafting = state.step else {
            return XCTFail("Novel symptom should land on the ticket preview, got \(state.step)")
        }

        // The preview became visible — the gate releases.
        (state, _) = reducer.reduce(state: state, action: .ticketPreviewPresented)
        XCTAssertFalse(state.pendingSendConsent, "Presenting the preview must release the send-consent gate")

        // A deliberate Send now goes through.
        let (submitting, effects) = reducer.reduce(state: state, action: .userConfirmedTicketSubmit)
        guard case .submitting = submitting.step else {
            return XCTFail("A confirm after the preview was seen must submit, got \(submitting.step)")
        }
        XCTAssertTrue(
            effects.contains { if case .submitTicket = $0 { return true }; return false },
            "A consented Send must emit the submitTicket effect"
        )
        XCTAssertFalse(
            submitting.messages.contains { if case .ticketPreview = $0.kind { return true }; return false },
            "The preview is removed once submission is in flight (F-002 contract)"
        )
    }

    // Chaos-qa F-002 regression: the ticketPreview message MUST be removed
    // from the message stream when the user confirms or cancels submission.
    // Without this, the UI renders an active preview card (Send/Cancel
    // buttons) next to the eventual "Sent" receipt — two contradictory
    // states visible at once.
    func testConfirmSubmit_removesTicketPreviewFromMessages_F002() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "novel issue",
            category: .reader,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let initial = ConversationState(
            step: .drafting(ticket: draft),
            messages: [
                .init(sender: .bot, kind: .text("Here's what I'll send:")),
                .init(sender: .bot, kind: .ticketPreview(draft))
            ]
        )
        let (next, _) = reducer.reduce(state: initial, action: .userConfirmedTicketSubmit)

        let previewCount = next.messages.filter { msg in
            if case .ticketPreview = msg.kind { return true }
            return false
        }.count
        XCTAssertEqual(previewCount, 0, "ticketPreview must be removed from message stream when leaving .drafting")
        XCTAssertTrue(next.messages.contains { msg in
            if case .text(let t) = msg.kind { return t.contains("Sending") }
            return false
        }, "A status text should land where the preview was")
    }

    func testCancelSubmit_alsoRemovesTicketPreview_F002() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "test",
            category: .reader,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let initial = ConversationState(
            step: .drafting(ticket: draft),
            messages: [.init(sender: .bot, kind: .ticketPreview(draft))]
        )
        let (next, _) = reducer.reduce(state: initial, action: .userCancelledTicketSubmit)

        let previewCount = next.messages.filter { msg in
            if case .ticketPreview = msg.kind { return true }
            return false
        }.count
        XCTAssertEqual(previewCount, 0, "Cancel must also drop the preview card; user explicitly declined")
    }

    /// Chaos-qa F-001 (2026-05-29) regression: cancelling a ticket draft
    /// must transition back to .awaitingCategory (NOT .sent), so the input
    /// bar remains available and the user can continue the conversation.
    /// The previous shape stranded users in .sent with no input affordance.
    func testCancelSubmit_returnsToAwaitingCategory_notSent_F001() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "test",
            category: .reader,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let initial = ConversationState(
            step: .drafting(ticket: draft),
            messages: [.init(sender: .bot, kind: .ticketPreview(draft))]
        )
        let (next, _) = reducer.reduce(state: initial, action: .userCancelledTicketSubmit)

        XCTAssertEqual(next.step, .awaitingCategory,
            "Cancel returns to awaitingCategory so input bar reappears")
        XCTAssertTrue(next.messages.contains { msg in
            if case .categoryChips = msg.kind { return true }
            return false
        }, "Fresh category chips must be offered so user can pick a different topic")
    }

    func testTicketSubmissionFailed_transportError_carriesDraftAndDoesNotLeakRawDetail() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "test",
            category: .reader,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let state = ConversationState(step: .submitting(ticket: draft))
        let rawDetail = "URLSession 503 backend-stacktrace-goes-here"
        let (next, effects) = reducer.reduce(
            state: state,
            action: .ticketSubmissionFailed(.transport(detail: rawDetail))
        )

        // PP-4808: error step must carry the failed draft so Retry re-submits it…
        guard case .error(let message, let failedDraft) = next.step else {
            return XCTFail("Expected .error, got \(next.step)")
        }
        XCTAssertEqual(failedDraft, draft, "Failed draft must be preserved for Retry / Copy details")
        // …and the raw technical detail must NOT be shown inline.
        XCTAssertFalse(message.contains(rawDetail), "Raw transport detail must not leak into the chat message")
        XCTAssertTrue(next.messages.contains { if case .errorActions = $0.kind { return true }; return false },
                      "Error card with recovery actions must be rendered")
        XCTAssertTrue(effects.contains(.persistPendingDraft(draft)),
                      "A real failure must persist the draft for the next session")
    }

    func testTicketSubmissionFailed_userCancelled_restoresPreviewInsteadOfDeadEnd() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "test",
            category: .reader,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let state = ConversationState(step: .submitting(ticket: draft))
        let (next, effects) = reducer.reduce(state: state, action: .ticketSubmissionFailed(.userCancelled))

        guard case .drafting(let restored) = next.step else {
            return XCTFail("A user cancel must restore the preview, got \(next.step)")
        }
        XCTAssertEqual(restored, draft)
        XCTAssertTrue(next.messages.contains { if case .ticketPreview = $0.kind { return true }; return false },
                      "Preview card must be re-offered on cancel")
        XCTAssertFalse(effects.contains(.persistPendingDraft(draft)),
                       "A cancel is not a failure — nothing to persist")
    }

    func testRetrySubmission_reSubmitsExactFailedDraft() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "retry me",
            category: .signin,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let state = ConversationState(step: .error(message: "nope", failedDraft: draft))
        let (next, effects) = reducer.reduce(state: state, action: .userTappedRetrySubmission)

        guard case .submitting(let resubmitted) = next.step else {
            return XCTFail("Retry must move to .submitting, got \(next.step)")
        }
        XCTAssertEqual(resubmitted, draft)
        XCTAssertTrue(effects.contains(.submitTicket(draft)), "Retry must re-emit the submit effect for the exact draft")
    }

    func testStartOver_fromError_resetsToChipsAndClearsPersistedDraft() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "x", category: .other,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let state = ConversationState(step: .error(message: "nope", failedDraft: draft))
        let (next, effects) = reducer.reduce(state: state, action: .userTappedStartOver)

        XCTAssertEqual(next.step, .awaitingCategory)
        XCTAssertTrue(effects.contains(.persistPendingDraft(nil)), "Start over must clear the persisted draft")
    }

    func testStart_emitsLoadPendingDraft_soAFailedDraftCanBeReoffered() {
        let reducer = makeReducer()
        let (_, effects) = reducer.reduce(state: ConversationState(), action: .start)
        XCTAssertTrue(effects.contains(.loadPendingDraft),
                      "Chat open must ask the host to re-offer any persisted pending draft")
    }

    func testRestorePendingDraft_reoffersPreview() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "unsent from last time", category: .download,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let (next, _) = reducer.reduce(state: ConversationState(step: .welcome), action: .restorePendingDraft(draft))

        guard case .drafting(let restored) = next.step else {
            return XCTFail("Expected .drafting, got \(next.step)")
        }
        XCTAssertEqual(restored, draft)
        XCTAssertTrue(next.messages.contains { if case .ticketPreview = $0.kind { return true }; return false })
    }

    func testTicketSubmitted_clearsPersistedPendingDraft() {
        let reducer = makeReducer()
        let draft = TicketDraft(
            userDescription: "x", category: .other,
            context: ContextSnapshot(appVersion: "3", appBuild: "1", osVersion: "26", deviceModel: "x")
        )
        let state = ConversationState(step: .submitting(ticket: draft))
        let (_, effects) = reducer.reduce(
            state: state,
            action: .ticketSubmitted(TicketReceipt(ticketId: "T-1", submittedAt: Date(timeIntervalSince1970: 0)))
        )
        XCTAssertTrue(effects.contains(.persistPendingDraft(nil)), "A successful send must clear the persisted draft")
    }

    // MARK: - Redactor integration

    func testContextLoaded_redactsSnapshotBeforeStoring() {
        let reducer = makeReducer()
        let raw = ContextSnapshot(
            appVersion: "3.0.3",
            appBuild: "478",
            osVersion: "26.4.2",
            deviceModel: "iPhone17,2",
            libraryUUID: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            recentLogLines: ["Authorization: Bearer secret-token-shouldnt-leak-12345"]
        )

        let (next, _) = reducer.reduce(state: ConversationState(), action: .contextLoaded(raw))

        XCTAssertNotNil(next.context)
        XCTAssertNotEqual(next.context?.libraryUUID, raw.libraryUUID, "UUID must be hashed by the time it lands in state")
        XCTAssertFalse(
            next.context?.recentLogLines.first?.contains("secret-token-shouldnt-leak-12345") ?? true,
            "Tokens must be stripped before context enters state"
        )
    }
}

// MARK: - Fixtures

private extension Array where Element == KBEntry {
    static var demoEntries: [KBEntry] {
        [
            KBEntry(
                id: "KI-2026-001-audiobook-first-open-hang",
                category: .audiobook,
                status: .open,
                fixedInVersion: "3.2.0",
                symptomKeywords: ["audiobook", "won't play", "spinning", "first time", "hangs"],
                distributorFilter: ["palace_marketplace"],
                userFacingWorkaround: "Tap back, tap again.",
                confidenceThreshold: 0.4,
                helpspotTag: "known-issue-PP-4436"
            ),
            KBEntry(
                id: "KI-2026-003-signin-placeholder-contrast",
                category: .signin,
                status: .fixedIn,
                fixedInVersion: "3.1.0",
                symptomKeywords: ["sign in", "grayed out", "can't type"],
                userFacingWorkaround: "Field is active — tap to type.",
                confidenceThreshold: 0.4,
                helpspotTag: "fixed-3.1.0"
            )
        ]
    }
}
