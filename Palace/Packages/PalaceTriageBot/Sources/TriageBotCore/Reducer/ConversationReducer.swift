import Foundation

/// Pure reducer that drives the chat. Mirrors Palace's existing
/// `Store<State, Action, Environment>` pattern (Palace/AppInfrastructure/
/// Store.swift) — `reduce(state, action) -> Effect` keeps the conversation
/// logic synchronous and testable; the iOS host runs effects on a Task.
///
/// The reducer is intentionally KB- and classifier-agnostic at the type
/// level: it takes them by value through the Environment so tests can supply
/// a synthetic KB without mocking.
public struct ConversationReducer: Sendable {
    public let classifier: LocalClassifier
    public let redactor: ContextRedactor
    public let knowledgeBase: KnowledgeBase

    /// Sentinel timestamp for receipts the reducer synthesizes for
    /// non-network paths (notify-me, cancel, dismiss). Keeps the response
    /// shape deterministic — those receipts are bookkeeping markers, not
    /// real ticket events, so they shouldn't claim a wall-clock time.
    /// Real submission receipts come from the gateway via `.ticketSubmitted`
    /// and DO carry the actual submission time.
    static let syntheticReceiptTimestamp = Date(timeIntervalSince1970: 0)

    public init(
        classifier: LocalClassifier = LocalClassifier(),
        redactor: ContextRedactor = ContextRedactor(),
        knowledgeBase: KnowledgeBase
    ) {
        self.classifier = classifier
        self.redactor = redactor
        self.knowledgeBase = knowledgeBase
    }

    /// Apply an action to a state. Returns the next state and a list of side
    /// effects the host should run (capture context, submit ticket, emit
    /// telemetry). Effects are intentionally *descriptive* — strings and
    /// values — so tests can assert what the host would have done.
    public func reduce(
        state: ConversationState,
        action: ConversationAction
    ) -> (state: ConversationState, effects: [ConversationEffect]) {
        var next = state
        var effects: [ConversationEffect] = []

        switch action {
        case .start:
            next.step = .awaitingCategory
            next.messages.append(.init(
                sender: .bot,
                kind: .text("What's happening? Tap a topic or describe the issue.")
            ))
            next.messages.append(.init(sender: .bot, kind: .categoryChips))
            effects.append(.captureContext)
            effects.append(.emitTelemetry(.init(name: "triage_chat_opened")))

        case .contextLoaded(let snapshot):
            next.context = redactor.redact(snapshot)

        case .userTappedCategory(let category):
            next.step = .awaitingDescription(category: category)
            next.messages.append(.init(
                sender: .user,
                kind: .text(displayName(for: category))
            ))
            next.messages.append(.init(
                sender: .bot,
                kind: .text(prompt(for: category))
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_category_chosen",
                parameters: ["category": category.rawValue]
            )))

        case .userTypedDescription(let text):
            next.inputText = text

        case .inputChanged(let text):
            next.inputText = text

        case .userSubmittedDescription:
            // Trim before checking — UI's Send button already debounces on
            // whitespace, but the reducer also enforces so any direct
            // dispatch (test harness, automation) can't produce a
            // whitespace-only "message". Caught by
            // AdversarialChaosTests.testReducer_emptyDescriptionSubmit_isNoOp.
            let userText = next.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userText.isEmpty else { return (next, effects) }
            let category: KBCategory?
            if case .awaitingDescription(let cat) = next.step { category = cat } else { category = nil }

            next.messages.append(.init(sender: .user, kind: .text(userText)))
            next.inputText = ""

            let result = classifier.classify(
                userText: userText,
                category: category,
                context: next.context,
                knowledgeBase: knowledgeBase
            )
            next.lastClassification = result

            switch result.decision {
            case .suggest(let entryId):
                next.step = .matched(entryId: entryId)
                next.messages.append(.init(sender: .bot, kind: .kbMatch(entryId: entryId)))
                effects.append(.emitTelemetry(.init(
                    name: "triage_kb_match",
                    parameters: [
                        "entry_id": entryId,
                        "confidence": String(format: "%.2f", result.confidence)
                    ]
                )))

            case .disambiguate(let candidates):
                next.messages.append(.init(
                    sender: .bot,
                    kind: .text("I see a few possibilities. Is this happening right now, or did it happen earlier today?")
                ))
                effects.append(.emitTelemetry(.init(
                    name: "triage_disambiguate",
                    parameters: ["candidate_count": String(candidates.count)]
                )))

            case .escalate:
                let draft = TicketDraft(
                    userDescription: userText,
                    category: category ?? .other,
                    matchedEntryId: nil,
                    context: next.context ?? emptyContext(),
                    helpspotTags: ["triage-bot-escalate-novel"],
                    priority: .normal
                )
                next.step = .drafting(ticket: draft)
                next.messages.append(.init(
                    sender: .bot,
                    kind: .text("I haven't seen exactly that before — let me file a ticket so support can look. Here's what I'll send:")
                ))
                next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
                effects.append(.emitTelemetry(.init(name: "triage_escalate_novel")))
            }

        case .userTappedNotifyMeOnFix(let entryId):
            // Synthesized marker receipt — no wall-clock timestamp.
            // Real ticket receipts (.ticketSubmitted) carry the gateway's
            // timestamp; these synthetic markers must stay deterministic
            // so the response to a given input is identical every time
            // (validated by ResponseDeterminismTests).
            next.step = .sent(receipt: TicketReceipt(ticketId: "notify-\(entryId)", submittedAt: Self.syntheticReceiptTimestamp))
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Got it. I'll let you know when the fix is on the App Store. Talk soon.")
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_user_notify_me",
                parameters: ["entry_id": entryId]
            )))

        case .userTappedFileTicketAnyway:
            guard case .matched(let entryId) = next.step,
                  let entry = knowledgeBase.entry(id: entryId) else { return (next, effects) }
            let draft = TicketDraft(
                userDescription: lastUserText(next.messages) ?? "(no description)",
                category: entry.category,
                matchedEntryId: entryId,
                context: next.context ?? emptyContext(),
                helpspotTags: [entry.helpspotTag ?? "triage-bot-known-issue", "user-requested-followup"],
                priority: .low
            )
            next.step = .drafting(ticket: draft)
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
            effects.append(.emitTelemetry(.init(
                name: "triage_user_file_anyway",
                parameters: ["entry_id": entryId]
            )))

        case .userTappedDismiss:
            next.step = .sent(receipt: TicketReceipt(ticketId: "dismissed", submittedAt: Self.syntheticReceiptTimestamp))
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Glad I could help. Reach back out anytime.")
            ))
            effects.append(.emitTelemetry(.init(name: "triage_user_dismiss")))

        case .userConfirmedTicketSubmit:
            guard case .drafting(let draft) = next.step else { return (next, effects) }
            next.step = .submitting(ticket: draft)
            effects.append(.submitTicket(draft))
            effects.append(.emitTelemetry(.init(
                name: "triage_ticket_submit_requested",
                parameters: ["priority": draft.priority.rawValue]
            )))

        case .userCancelledTicketSubmit:
            next.step = .sent(receipt: TicketReceipt(ticketId: "cancelled", submittedAt: Self.syntheticReceiptTimestamp))
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Cancelled — nothing was sent.")
            ))

        case .ticketSubmitted(let receipt):
            next.step = .sent(receipt: receipt)
            next.messages.append(.init(sender: .bot, kind: .ticketReceipt(receipt)))
            effects.append(.emitTelemetry(.init(
                name: "triage_ticket_submitted",
                parameters: ["ticket_id": receipt.ticketId]
            )))

        case .ticketSubmissionFailed(let message):
            next.step = .error(message: message)
            next.messages.append(.init(
                sender: .bot,
                kind: .text("I couldn't send the ticket — \(message). You can try again, or copy the details and email support.")
            ))
            effects.append(.emitTelemetry(.init(name: "triage_ticket_submit_failed")))

        case .userAnsweredFollowUp:
            // Phase 2 — disambiguation answer flow lands here. For demo we
            // treat follow-up as a category re-prompt and let the user
            // re-describe the issue.
            break
        }

        return (next, effects)
    }

    // MARK: - Helpers

    private func displayName(for category: KBCategory) -> String {
        switch category {
        case .audiobook: return "Audiobook issue"
        case .reader: return "Book / reading issue"
        case .signin: return "Sign in issue"
        case .download: return "Download issue"
        case .library: return "Library / account"
        case .other: return "Other"
        }
    }

    private func prompt(for category: KBCategory) -> String {
        switch category {
        case .audiobook:
            return "Tell me what's happening with your audiobook."
        case .reader:
            return "Tell me what's happening when you try to read."
        case .signin:
            return "Tell me what happens when you try to sign in."
        case .download:
            return "Tell me what's happening with the download."
        case .library:
            return "Tell me what's happening with your library or account."
        case .other:
            return "Describe what's going on and I'll do my best to help."
        }
    }

    private func lastUserText(_ messages: [ConversationMessage]) -> String? {
        for message in messages.reversed() {
            if message.sender == .user, case .text(let text) = message.kind {
                return text
            }
        }
        return nil
    }

    private func emptyContext() -> ContextSnapshot {
        ContextSnapshot(
            appVersion: "unknown",
            appBuild: "unknown",
            osVersion: "unknown",
            deviceModel: "unknown"
        )
    }
}

/// Descriptive side effect — host translates to real work (NWPathMonitor
/// snapshot, HelpSpot HTTP POST, Firebase event). Effects are values so the
/// reducer stays pure and tests assert on the list directly.
public enum ConversationEffect: Equatable, Sendable {
    case captureContext
    case submitTicket(TicketDraft)
    case emitTelemetry(TelemetryEvent)
}
