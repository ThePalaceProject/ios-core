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
    private let remedyDetector = RemedyDetector()
    public let redactor: ContextRedactor
    public let knowledgeBase: KnowledgeBase
    /// When true, local-classifier escalations route through
    /// `.awaitingAIClassification` first so a network-backed
    /// FallbackClassifier (ClaudeFallbackClassifier in production) gets a
    /// chance to match. When false, the reducer's behavior is the original
    /// keyword-only flow — escalate goes straight to .drafting.
    /// Defaults to false so the existing 69-test suite stays green and
    /// any consumer that doesn't wire a fallback gets predictable behavior.
    public let aiFallbackEnabled: Bool

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
        knowledgeBase: KnowledgeBase,
        aiFallbackEnabled: Bool = false
    ) {
        self.classifier = classifier
        self.redactor = redactor
        self.knowledgeBase = knowledgeBase
        self.aiFallbackEnabled = aiFallbackEnabled
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
            // PP-4808: if a ticket failed to send last session, the host has
            // it persisted — ask it to re-offer via .restorePendingDraft.
            effects.append(.loadPendingDraft)
            effects.append(.emitTelemetry(.init(name: "triage_chat_opened")))

        case .contextLoaded(let snapshot):
            let redacted = redactor.redact(snapshot)
            next.context = redacted
            // PP-4811: the user can race ahead to a ticket draft before the
            // async context capture returns. If that happened, the draft holds
            // an all-"unknown" placeholder context — bind the real one in now so
            // no ticket ships with an empty environment.
            lateBindContext(&next, context: redacted)

        case .userTappedCategory(let category):
            // Debounce rapid / double taps (chaos F-001, PP-4822). Category chips
            // are only shown while awaiting a category; once the first tap moves us
            // to .awaitingDescription, further taps are no-ops — otherwise an eager
            // patron appends several duplicate turns and the chat looks broken. This
            // mirrors the Send button's debounce.
            guard case .awaitingCategory = next.step else { return (next, effects) }
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
            // Read what they have already done BEFORE deciding what to suggest.
            next.alreadyTriedRemedies = remedyDetector.alreadyTried(in: userText)
            next.claimsExhaustedEffort = remedyDetector.claimsExhaustedEffort(in: userText)

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
                // How confidently we SPEAK the match is separate from whether we
                // make it. Two things force a hedge:
                //
                //  - a non-`authoritative` entry, which is a maybe by definition;
                //  - evidence resting on ONE matched concept. A single decisive
                //    phrase is enough to offer the entry — that is the fix for the
                //    "I haven't seen exactly that before" complaint — but it is
                //    also the thinnest evidence that can produce a suggestion, and
                //    the near-miss corpus shows single-concept matches are where
                //    real misroutes live. Stating a one-concept guess as fact is
                //    what turns a wrong guess into wrong instructions; asking
                //    turns it into a tap. Two of the entries reachable this way
                //    advise signing out and back in, which given the DRM
                //    data-loss history (PP-4951) is not free advice to hand the
                //    wrong patron.
                let entry = knowledgeBase.entry(id: entryId)
                let thinEvidence = result.strongRegionCount <= 1
                let untrusted = entry?.trustLevel != .authoritative
                if untrusted || thinEvidence {
                    next.messages.append(.init(
                        sender: .bot,
                        kind: .text(thinEvidence && !untrusted
                            ? "This sounds like it might be the problem below — does that match what you're seeing?"
                            : "This might be what's going on — take a look:")
                    ))
                }
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
                if aiFallbackEnabled {
                    // Local matcher had nothing — let the AI fallback weigh
                    // in before we commit to escalating. UX: bot shows a
                    // thinking indicator; ViewModel handles the
                    // .runAIFallback effect by calling the
                    // FallbackClassifier; result feeds back as
                    // .aiFallbackResolved or .aiFallbackUnavailable.
                    next.step = .awaitingAIClassification(userText: userText, category: category)
                    next.messages.append(.init(
                        sender: .bot,
                        kind: .text("Let me check that more carefully…")
                    ))
                    effects.append(.runAIFallback(
                        userText: userText,
                        category: category,
                        context: next.context
                    ))
                    effects.append(.emitTelemetry(.init(name: "triage_ai_fallback_invoked")))
                } else {
                    // If the classifier RECOGNIZED a topic but escalated (a
                    // low-confidence match, or an escalate_anyway entry), carry
                    // that entry through: transitionToDrafting asks its targeted
                    // escalation follow-up and tags the ticket with it, instead of
                    // handing support a blank "couldn't help." nil = a genuine
                    // no-match (novel issue).
                    let recognized = result.recognizedEntryId

                    // Nothing matched, or matched only weakly — this is ~88% of
                    // real complaints. Offer the category's remedy ladder before
                    // filing, rather than only asking a question.
                    //
                    // Not offered when the patron said they had tried everything,
                    // and never for escalate_anyway entries (handled in the
                    // classifier — those never reach this arm with a suggestion).
                    // `escalate_anyway` means the entry was recognized WITH
                    // confidence and has no safe self-serve fix — the account-side
                    // and library-side class that is a quarter of real tickets.
                    // Offering remedies there is delay dressed as help, and it
                    // contradicts the entry's own declaration.
                    let staffOnly = recognized
                        .flatMap { knowledgeBase.entry(id: $0) }?
                        .escalateAnyway ?? false

                    if !next.claimsExhaustedEffort, !staffOnly,
                       let flow = knowledgeBase.genericFlow(for: category) {
                        next.step = .matched(entryId: flow.id)
                        next.messages.append(.init(
                            sender: .bot, kind: .kbMatch(entryId: flow.id)))
                        effects.append(.emitTelemetry(.init(
                            name: "triage_generic_ladder_offered",
                            parameters: ["category": category?.rawValue ?? "(none)"]
                        )))
                        return (next, effects)
                    }

                    transitionToDrafting(
                        state: &next,
                        effects: &effects,
                        userText: userText,
                        category: category,
                        matchedEntryId: recognized,
                        tagSuffix: recognized != nil ? "escalate-recognized" : "escalate-novel",
                        // Weak-only recognition still scopes the ticket, but must
                        // not interrogate the patron about a bug we have not
                        // actually identified.
                        mayAskTargetedFollowUp: result.recognitionIsStrong
                    )
                }
            }

        // MARK: - AI fallback resolution

        case .aiFallbackResolved(let result):
            guard case .awaitingAIClassification(let userText, let category) = next.step else {
                return (next, effects)
            }
            next.lastClassification = result
            switch result.decision {
            case .suggest(let entryId):
                next.step = .matched(entryId: entryId)
                next.messages.append(.init(sender: .bot, kind: .kbMatch(entryId: entryId)))
                effects.append(.emitTelemetry(.init(
                    name: "triage_ai_fallback_match",
                    parameters: [
                        "entry_id": entryId,
                        "confidence": String(format: "%.2f", result.confidence)
                    ]
                )))
            case .disambiguate, .escalate:
                // Either Claude wasn't confident enough or genuinely couldn't
                // match — fall through to standard escalate behavior with
                // the original user text + category preserved.
                transitionToDrafting(
                    state: &next,
                    effects: &effects,
                    userText: userText,
                    category: category,
                    matchedEntryId: nil,
                    tagSuffix: "escalate-novel-after-ai-pass"
                )
            }

        case .aiFallbackUnavailable:
            guard case .awaitingAIClassification(let userText, let category) = next.step else {
                return (next, effects)
            }
            // Offline / timeout / API key missing / rate-limit / parse error —
            // any failure mode degrades to the standard escalate path. User
            // never sees the failure as an error; they just get the ticket
            // preview a moment later than they would have.
            transitionToDrafting(
                state: &next,
                effects: &effects,
                userText: userText,
                category: category,
                matchedEntryId: nil,
                tagSuffix: "escalate-after-ai-unavailable"
            )
            effects.append(.emitTelemetry(.init(name: "triage_ai_fallback_unavailable")))

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
                // PP-4805: the last user message is raw free text — route it
                // through the redactor before it can land in a ticket.
                userDescription: redactor.redactLine(lastUserText(next.messages) ?? "(no description)"),
                category: entry.category,
                matchedEntryId: entryId,
                context: next.context ?? emptyContext(),
                helpspotTags: [entry.helpspotTag ?? "triage-bot-known-issue", "user-requested-followup"],
                priority: .low,
                omittedFields: initialOmittedFields(next.context)
            )
            // Route through the follow-up gate too — even when the user
            // explicitly bails on the workaround, the entry's structured
            // follow-up question still adds value to support's ticket.
            askEscalationFollowUpOrDraft(
                state: &next,
                effects: &effects,
                entryId: entryId,
                draft: draft,
                tagSuffix: "user-file-anyway"
            )
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

        // MARK: - Guided troubleshooting flow

        case .userTappedStartGuidedFlow(let entryId):
            guard let entry = knowledgeBase.entry(id: entryId),
                  let steps = entry.userFacingSteps,
                  !steps.isEmpty else {
                return (next, effects)
            }
            let startedAt = Date()
            // Skip anything they already told us they did. If that is every step,
            // there is nothing left to walk through and the honest move is to
            // escalate with the trace rather than open an empty flow.
            let skipped = Set(steps.compactMap(\.remedy)).intersection(next.alreadyTriedRemedies)
            guard let firstIndex = nextUntriedStepIndex(
                from: 0, steps: steps, alreadyTried: next.alreadyTriedRemedies
            ) else {
                if let ack = acknowledgement(for: skipped) {
                    next.messages.append(.init(sender: .bot, kind: .text(ack)))
                }
                effects.append(.emitTelemetry(.init(
                    name: "triage_guided_flow_all_steps_already_tried",
                    parameters: ["entry_id": entryId]
                )))
                escalateWithTrace(
                    state: &next, effects: &effects,
                    userText: next.messages.compactMap {
                        if case .text(let t) = $0.kind, $0.sender == .user { return t }
                        return nil
                    }.last ?? "",
                    category: entry.category,
                    matchedEntryId: entryId,
                    trace: ResolutionTrace(entryId: entryId, attempts: [],
                                           startedAt: startedAt, endedAt: Date(),
                                           outcome: .escalatedAfterStepsExhausted),
                    helpspotTag: entry.helpspotTag ?? entryId,
                    tagSuffix: "escalate-all-steps-already-tried"
                )
                return (next, effects)
            }
            next.step = .guidedStep(
                entryId: entryId,
                stepIndex: firstIndex,
                startedAt: startedAt,
                attempts: []
            )
            if let ack = acknowledgement(for: skipped) {
                next.messages.append(.init(sender: .bot, kind: .text(ack)))
            }
            let remaining = steps.count - skipped.count
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Let's walk through this together. \(remaining) thing\(remaining == 1 ? "" : "s") to try.")
            ))
            next.messages.append(.init(
                sender: .bot,
                kind: .guidedStep(entryId: entryId, stepIndex: firstIndex)
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_guided_flow_started",
                parameters: ["entry_id": entryId, "step_count": String(steps.count)]
            )))

        case .userConfirmedStepResolved(let stepId):
            guard case .guidedStep(let entryId, _, let startedAt, var attempts) = next.step else {
                return (next, effects)
            }
            attempts.append(StepAttempt(stepId: stepId, outcome: .resolved, timestamp: Date()))
            let trace = ResolutionTrace(
                entryId: entryId,
                attempts: attempts,
                startedAt: startedAt,
                endedAt: Date(),
                outcome: .resolved
            )
            next.step = .sent(receipt: TicketReceipt(
                ticketId: "guided-resolved-\(entryId)-\(stepId)",
                submittedAt: Self.syntheticReceiptTimestamp
            ))
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Glad that worked. I've recorded which step did the trick — that helps us tune the workaround for the next person.")
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_guided_step_resolved",
                parameters: [
                    "entry_id": entryId,
                    "step_id": stepId,
                    "steps_attempted": String(attempts.count)
                ]
            )))
            // Phase 2: persist trace to a local backfill log so a server-
            // backed catalog source can ingest per-step success rates.
            _ = trace

        case .userConfirmedStepDidNotResolve(let stepId):
            guard case .guidedStep(let entryId, let stepIndex, let startedAt, var attempts) = next.step,
                  let entry = knowledgeBase.entry(id: entryId),
                  let steps = entry.userFacingSteps else {
                return (next, effects)
            }
            attempts.append(StepAttempt(stepId: stepId, outcome: .didNotResolve, timestamp: Date()))

            let nextIndex = nextUntriedStepIndex(
                from: stepIndex + 1, steps: steps, alreadyTried: next.alreadyTriedRemedies
            ) ?? steps.count
            if nextIndex < steps.count {
                next.step = .guidedStep(
                    entryId: entryId,
                    stepIndex: nextIndex,
                    startedAt: startedAt,
                    attempts: attempts
                )
                next.messages.append(.init(
                    sender: .bot,
                    kind: .text("OK, let's try one more thing.")
                ))
                next.messages.append(.init(
                    sender: .bot,
                    kind: .guidedStep(entryId: entryId, stepIndex: nextIndex)
                ))
                effects.append(.emitTelemetry(.init(
                    name: "triage_guided_step_advanced",
                    parameters: [
                        "entry_id": entryId,
                        "step_id": stepId,
                        "next_index": String(nextIndex)
                    ]
                )))
            } else {
                // Steps exhausted — escalate with the full trace attached.
                let trace = ResolutionTrace(
                    entryId: entryId,
                    attempts: attempts,
                    startedAt: startedAt,
                    endedAt: Date(),
                    outcome: .escalatedAfterStepsExhausted
                )
                escalateWithTrace(
                    state: &next,
                    effects: &effects,
                    userText: lastUserText(next.messages) ?? "(no description)",
                    category: entry.category,
                    matchedEntryId: entryId,
                    trace: trace,
                    helpspotTag: entry.helpspotTag ?? "triage-bot-known-issue",
                    tagSuffix: "escalate-after-guided-flow-exhausted"
                )
            }

        case .userSelectedStepResponse(let stepId, let responseIndex):
            // Outcome-driven routing. Looks up the response's `.outcome`
            // and dispatches to the same internal handlers as the legacy
            // resolved/didNotResolve actions. Means a single step with
            // explicit responses can behave differently per branch —
            // diagnostic intermediate steps map "yes" to `.advance`
            // (not "resolved"), final steps map "yes" to `.resolved`.
            guard case .guidedStep(let entryId, _, _, _) = next.step,
                  let entry = knowledgeBase.entry(id: entryId),
                  let steps = entry.userFacingSteps,
                  let step = steps.first(where: { $0.id == stepId }),
                  let responses = step.responses,
                  responseIndex >= 0, responseIndex < responses.count else {
                return (next, effects)
            }
            let response = responses[responseIndex]
            switch response.outcome {
            case .resolved:
                let (resolvedNext, resolvedEffects) = reduce(
                    state: next,
                    action: .userConfirmedStepResolved(stepId: stepId)
                )
                return (resolvedNext, effects + resolvedEffects)
            case .advance:
                let (advancedNext, advancedEffects) = reduce(
                    state: next,
                    action: .userConfirmedStepDidNotResolve(stepId: stepId)
                )
                return (advancedNext, effects + advancedEffects)
            case .escalate:
                let (abandonNext, abandonEffects) = reduce(
                    state: next,
                    action: .userTappedAbandonGuidedFlow
                )
                return (abandonNext, effects + abandonEffects)
            }

        case .userTappedAbandonGuidedFlow:
            guard case .guidedStep(let entryId, _, let startedAt, var attempts) = next.step,
                  let entry = knowledgeBase.entry(id: entryId) else {
                return (next, effects)
            }
            // Record an abandon marker so the trace shows the user explicitly
            // exited rather than completing the flow. Useful signal: "step 2
            // is where most users give up."
            if let lastStep = attempts.last?.stepId {
                attempts.append(StepAttempt(stepId: lastStep, outcome: .abandoned, timestamp: Date()))
            }
            let trace = ResolutionTrace(
                entryId: entryId,
                attempts: attempts,
                startedAt: startedAt,
                endedAt: Date(),
                outcome: .abandoned
            )
            escalateWithTrace(
                state: &next,
                effects: &effects,
                userText: lastUserText(next.messages) ?? "(no description)",
                category: entry.category,
                matchedEntryId: entryId,
                trace: trace,
                helpspotTag: entry.helpspotTag ?? "triage-bot-known-issue",
                tagSuffix: "escalate-after-guided-flow-abandoned"
            )

        case .ticketPreviewPresented:
            // PP-4843: the preview card is now on screen and the patron can
            // read it — release the send-consent gate so a deliberate Send
            // goes through. Idempotent and safe from any state.
            next.pendingSendConsent = false

        case .userConfirmedTicketSubmit:
            guard case .drafting(let draft) = next.step else { return (next, effects) }
            // PP-4843 (chaos rapid-tap): on a short conversation the preview's
            // own Send button renders at the same screen position the message
            // Send arrow occupied before the auto-scroll, so a rapid burst that
            // began as message-submit taps bleeds a confirm tap onto the
            // just-appeared preview before the patron ever saw it. The reducer
            // arms `pendingSendConsent` whenever it presents a FRESH preview and
            // only the card's `.ticketPreviewPresented` (fired on a later
            // runloop turn) clears it — so a confirm that arrives while the gate
            // is still armed is that same-burst accidental tap. Suppress it: the
            // patron must actually see the preview before a ticket is filed.
            // Mirrors the PP-4822 category-chip debounce class. (A directly
            // constructed drafting state defaults to an un-armed gate, so
            // deliberate single-tap sends are unaffected.)
            if next.pendingSendConsent {
                return (next, effects)
            }
            // Chaos-qa F-002: drop the ticketPreview from the message log
            // when leaving .drafting so the user doesn't see active Send /
            // Cancel buttons stacked next to the eventual "Sent" receipt.
            // The preview was an in-the-moment affordance; once submission
            // is in flight, replace it with a status line.
            next.messages.removeAll { msg in
                if case .ticketPreview = msg.kind { return true }
                return false
            }
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Sending your ticket…")
            ))
            next.step = .submitting(ticket: draft)
            // PP-4883: the draft leaves the reducer WIRE-READY — every field the
            // patron switched off is stripped here, in pure Core, before any
            // gateway sees it. This is the single chokepoint that makes the
            // omit-choices guarantee independent of which gateway runs (email,
            // clipboard, a future HelpSpot POST) and testable under the fast
            // `swift test` gate. `.submitting(ticket: draft)` keeps the original
            // draft so the failure/retry/persist path still shows what the
            // patron reviewed. `sanitizedForSubmission()` is idempotent, so the
            // gateway's own serialization sanitize is harmless defense-in-depth.
            effects.append(.submitTicket(draft.sanitizedForSubmission()))
            effects.append(.emitTelemetry(.init(
                name: "triage_ticket_submit_requested",
                parameters: ["priority": draft.priority.rawValue]
            )))

        case .userCancelledTicketSubmit:
            // Drop the preview card so it can't be re-tapped (F-002 rationale).
            next.messages.removeAll { msg in
                if case .ticketPreview = msg.kind { return true }
                return false
            }
            // Chaos-qa F-001 (2026-05-29): the previous shape transitioned
            // to .sent on cancel, which hid the input bar and stranded the
            // user with no way to continue. Cancel should mean "I'm not
            // ready to submit, let me start over" — so we return to
            // .awaitingCategory and offer fresh category chips. The
            // input bar becomes available again because awaitingCategory
            // is in the isCompositionStep set.
            next.step = .awaitingCategory
            next.messages.append(.init(
                sender: .bot,
                kind: .text("No problem — nothing was sent. Want to try a different category or rephrase?")
            ))
            next.messages.append(.init(sender: .bot, kind: .categoryChips))
            effects.append(.emitTelemetry(.init(name: "triage_ticket_cancel_returned_to_chips")))

        case .userToggledDraftField(let field):
            guard case .drafting(let draft) = next.step else { return (next, effects) }
            var omitted = draft.omittedFields
            let nowOmitted: Bool
            if omitted.contains(field) { omitted.remove(field); nowOmitted = false }
            else { omitted.insert(field); nowOmitted = true }
            let updated = draft.withOmittedFields(omitted)
            next.step = .drafting(ticket: updated)
            replaceTicketPreview(&next, with: updated)
            effects.append(.emitTelemetry(.init(
                name: "triage_draft_field_toggled",
                parameters: ["field": field.rawValue, "omitted": String(nowOmitted)]
            )))

        case .userOmittedLogs(let omit):
            guard case .drafting(let draft) = next.step else { return (next, effects) }
            var omitted = draft.omittedFields
            if omit { omitted.insert(.logs) } else { omitted.remove(.logs) }
            let updated = draft.withOmittedFields(omitted)
            next.step = .drafting(ticket: updated)
            replaceTicketPreview(&next, with: updated)
            effects.append(.emitTelemetry(.init(
                name: "triage_draft_field_toggled",
                parameters: ["field": "logs", "omitted": String(omit)]
            )))

        case .userEditedDescription(let text):
            guard case .drafting(let draft) = next.step else { return (next, effects) }
            // PP-4805: an edited description is still patron free text — redact it.
            let updated = draft.withUserDescription(redactor.redactLine(text))
            next.step = .drafting(ticket: updated)
            replaceTicketPreview(&next, with: updated)

        case .ticketSubmitted(let receipt):
            next.step = .sent(receipt: receipt)
            next.messages.append(.init(sender: .bot, kind: .ticketReceipt(receipt)))
            // PP-4808: submission succeeded — clear any persisted pending draft
            // so it isn't re-offered on the next chat open.
            effects.append(.persistPendingDraft(nil))
            effects.append(.emitTelemetry(.init(
                name: "triage_ticket_submitted",
                parameters: ["ticket_id": receipt.ticketId]
            )))

        case .ticketSubmissionFailed(let failure):
            // PP-4808: never dead-end. Pull the in-flight draft so every
            // recovery path (retry / restore) has the exact ticket.
            let inFlight: TicketDraft?
            if case .submitting(let ticket) = next.step { inFlight = ticket } else { inFlight = nil }

            switch failure {
            case .userCancelled:
                // The user backed out of the OS composer — NOT a failure.
                // Restore the preview so they can send again or cancel for real.
                if let draft = inFlight {
                    next.step = .drafting(ticket: draft)
                    next.messages.append(.init(
                        sender: .bot,
                        kind: .text(UserFacingErrorMessage.from(failure))
                    ))
                    next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
                } else {
                    // No draft to restore — fall back to fresh chips.
                    next.step = .awaitingCategory
                    next.messages.append(.init(
                        sender: .bot,
                        kind: .text("No problem — nothing was sent. Want to try a different category?")
                    ))
                    next.messages.append(.init(sender: .bot, kind: .categoryChips))
                }
                effects.append(.emitTelemetry(.init(name: "triage_ticket_submit_cancelled_by_user")))

            case .transport:
                next.step = .error(message: UserFacingErrorMessage.from(failure), failedDraft: inFlight)
                next.messages.append(.init(
                    sender: .bot,
                    kind: .text(UserFacingErrorMessage.from(failure))
                ))
                next.messages.append(.init(sender: .bot, kind: .errorActions(draft: inFlight)))
                // Persist so a real failure survives to the next chat open.
                effects.append(.persistPendingDraft(inFlight))
                effects.append(.emitTelemetry(.init(name: "triage_ticket_submit_failed")))
            }

        case .userTappedRetrySubmission:
            guard case .error(_, let failedDraft) = next.step, let draft = failedDraft else {
                return (next, effects)
            }
            next.messages.append(.init(sender: .bot, kind: .text("Trying again…")))
            next.step = .submitting(ticket: draft)
            // PP-4883: sanitize on the retry path too (see .userConfirmedTicketSubmit).
            effects.append(.submitTicket(draft.sanitizedForSubmission()))
            effects.append(.emitTelemetry(.init(name: "triage_ticket_submit_retried")))

        case .userTappedStartOver:
            next.step = .awaitingCategory
            // "Start fresh" means a clean composer: drop any half-typed input so
            // the next description begins empty (PP-4846). Mirrors Discard, which
            // also returns to .awaitingCategory with no carried-over text — the
            // two reset paths now have identical composer semantics.
            next.inputText = ""
            next.messages.append(.init(
                sender: .bot,
                kind: .text("OK — let's start fresh. What's happening?")
            ))
            next.messages.append(.init(sender: .bot, kind: .categoryChips))
            // Starting over abandons the failed draft — clear it.
            effects.append(.persistPendingDraft(nil))
            effects.append(.emitTelemetry(.init(name: "triage_ticket_start_over")))

        case .restorePendingDraft(let draft):
            // PP-4808: a ticket failed to send in a prior session; re-offer it.
            next.step = .drafting(ticket: draft)
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Last time, a ticket didn't finish sending. Here it is again — tap Send to try, or start over.")
            ))
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
            effects.append(.emitTelemetry(.init(name: "triage_pending_draft_restored")))

        case .userAnsweredFollowUp:
            // Phase 2 — disambiguation answer flow lands here. For demo we
            // treat follow-up as a category re-prompt and let the user
            // re-describe the issue.
            break

        case .userAnsweredEscalationFollowUp(let answer):
            guard case .awaitingEscalationFollowUp(let prompt, let pendingDraft) = next.step else {
                return (next, effects)
            }
            // Merge the answer (or skip marker) into the draft and proceed
            // to the standard drafting / preview flow.
            // PP-4805: the follow-up answer is raw patron free text —
            // redact it before it attaches to the draft / email body.
            let redactedAnswer = answer.map(redactor.redactLine)
            let enriched = TicketDraft(
                userDescription: pendingDraft.userDescription,
                category: pendingDraft.category,
                matchedEntryId: pendingDraft.matchedEntryId,
                context: pendingDraft.context,
                helpspotTags: pendingDraft.helpspotTags + [
                    answer == nil ? "escalation-follow-up-skipped" : "escalation-follow-up-answered"
                ],
                priority: pendingDraft.priority,
                resolutionTrace: pendingDraft.resolutionTrace,
                escalationFollowUp: EscalationFollowUpAnswer(prompt: prompt, answer: redactedAnswer),
                omittedFields: pendingDraft.omittedFields
            )
            next.step = .drafting(ticket: enriched)
            next.inputText = ""
            // PP-4843: the follow-up answer presents a fresh preview — arm the
            // send-consent gate so a rapid tap after answering can't skip it.
            next.pendingSendConsent = true
            // Append a user-side message showing what they answered (or a
            // "(skipped)" marker) so the chat history reads naturally.
            if let answer, !answer.isEmpty {
                next.messages.append(.init(sender: .user, kind: .text(answer)))
            } else {
                next.messages.append(.init(
                    sender: .bot,
                    kind: .text("(skipped)")
                ))
            }
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Thanks. Here's what I'll send to support:")
            ))
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(enriched)))
            effects.append(.emitTelemetry(.init(
                name: answer == nil ? "triage_escalation_followup_skipped" : "triage_escalation_followup_answered",
                parameters: [
                    "entry_id": pendingDraft.matchedEntryId ?? "(none)"
                ]
            )))
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

    /// Replaces the most recent `.ticketPreview` message in place so the card
    /// re-renders with the edited draft without duplicating the row (PP-4807).
    /// Appends one if none exists yet.
    private func replaceTicketPreview(_ next: inout ConversationState, with draft: TicketDraft) {
        if let idx = next.messages.lastIndex(where: { if case .ticketPreview = $0.kind { return true }; return false }) {
            let old = next.messages[idx]
            next.messages[idx] = ConversationMessage(id: old.id, sender: old.sender, kind: .ticketPreview(draft), timestamp: old.timestamp)
        } else {
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
        }
    }

    /// PP-4811: bind a late-arriving context into a draft that was built with
    /// the placeholder (empty) context. Only rebinds placeholder drafts so a
    /// restored draft's real context is never clobbered. Re-applies the
    /// barcode default-omit now that the real context may carry a barcode.
    private func lateBindContext(_ next: inout ConversationState, context: ContextSnapshot) {
        func rebound(_ draft: TicketDraft) -> TicketDraft? {
            guard draft.context.isPlaceholder else { return nil }
            let omissions = draft.omittedFields.union(initialOmittedFields(context))
            return draft.withContext(context).withOmittedFields(omissions)
        }
        switch next.step {
        case .drafting(let d):
            if let u = rebound(d) {
                next.step = .drafting(ticket: u)
                replaceTicketPreview(&next, with: u)
            }
        case .submitting(let d):
            if let u = rebound(d) { next.step = .submitting(ticket: u) }
        case .awaitingEscalationFollowUp(let prompt, let d):
            if let u = rebound(d) { next.step = .awaitingEscalationFollowUp(prompt: prompt, pendingDraft: u) }
        default:
            break
        }
    }

    /// Initial omit set for a freshly-assembled draft. The library barcode is
    /// opt-IN — captured (as a hash) but left out of the outgoing ticket by
    /// default (PP-4807). Everything else defaults to included.
    private func initialOmittedFields(_ context: ContextSnapshot?) -> Set<TicketField> {
        (context?.libraryBarcode != nil) ? [.barcode] : []
    }

    private func lastUserText(_ messages: [ConversationMessage]) -> String? {
        for message in messages.reversed() {
            if message.sender == .user, case .text(let text) = message.kind {
                return text
            }
        }
        return nil
    }

    /// First step at or after `from` that the patron has NOT already tried.
    /// Returns nil when every remaining step is one they have done.
    private func nextUntriedStepIndex(
        from index: Int, steps: [KBStep], alreadyTried: Set<Remedy>
    ) -> Int? {
        var i = index
        while i < steps.count {
            if let remedy = steps[i].remedy, alreadyTried.contains(remedy) { i += 1; continue }
            return i
        }
        return nil
    }

    /// "You have already tried X and Y" — said once, so skipping does not look
    /// like steps silently going missing.
    private func acknowledgement(for remedies: Set<Remedy>) -> String? {
        guard !remedies.isEmpty else { return nil }
        let names = remedies.map(\.displayName).sorted()
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
        return "You have already tried \(list), so I will skip that."
    }

    /// Shared escalation transition — used by both the local-only escalate
    /// path AND the post-AI-fallback escalate path so the resulting message
    /// stream + state is identical regardless of which classifier escalated.
    ///
    /// If the matched entry defines an `escalationFollowUp`, pauses to ask
    /// the question first and routes through `.awaitingEscalationFollowUp`
    /// — the answer attaches to the draft and the user lands at the
    /// preview a moment later. Entries without a follow-up go straight to
    /// the preview (current behavior).
    private func transitionToDrafting(
        state next: inout ConversationState,
        effects: inout [ConversationEffect],
        userText: String,
        category: KBCategory?,
        matchedEntryId: String?,
        tagSuffix: String,
        // Whether the recognition is strong enough to justify the entry's
        // bug-presuming follow-up question. The ticket is scoped either way;
        // only the patron-facing question is gated. Defaults true — callers
        // that got here from a guided flow have watched the patron walk the
        // entry's own steps, which is the strongest recognition there is.
        mayAskTargetedFollowUp: Bool = true
    ) {
        let draft = TicketDraft(
            // PP-4805: redact patron-typed free text at draft assembly.
            userDescription: redactor.redactLine(userText),
            category: category ?? .other,
            matchedEntryId: matchedEntryId,
            context: next.context ?? emptyContext(),
            helpspotTags: ["triage-bot-\(tagSuffix)"],
            priority: .normal,
            omittedFields: initialOmittedFields(next.context)
        )
        askEscalationFollowUpOrDraft(
            state: &next,
            effects: &effects,
            entryId: matchedEntryId,
            draft: draft,
            tagSuffix: tagSuffix,
            recognitionIsStrong: mayAskTargetedFollowUp
        )
    }

    /// Pivots between "ask a follow-up question first" and "go straight
    /// to the ticket preview" based on whether the matched entry has an
    /// `escalationFollowUp` defined. Used by both transitionToDrafting
    /// and escalateWithTrace so the contract is consistent.
    private func askEscalationFollowUpOrDraft(
        state next: inout ConversationState,
        effects: inout [ConversationEffect],
        entryId: String?,
        draft: TicketDraft,
        tagSuffix: String,
        // True when the recognition rests on a decisive phrase. A prompt that
        // presumes the issue is only asked then; a prompt marked
        // `presumes_issue: false` is safe either way, because it asks about the
        // patron's situation rather than about a bug we may have misread.
        recognitionIsStrong: Bool = true
    ) {
        // Prefer the recognized entry's own question; fall back to the category's.
        //
        // A blank ticket is the worst thing this bot can produce, and 69% of
        // escalations were producing one. The category question does not claim to
        // know the cause — it asks the thing that most often separates that
        // category's clusters — so it is safe precisely when we know least.
        let entryFollowUp: KBEscalationFollowUp? = {
            guard let entryId, let entry = knowledgeBase.entry(id: entryId),
                  let followUp = entry.escalationFollowUp,
                  recognitionIsStrong || !followUp.presumesIssue else { return nil }
            return followUp
        }()
        let followUp = entryFollowUp ?? knowledgeBase.categoryFollowUp(for: draft.category)

        if let followUp {
            next.step = .awaitingEscalationFollowUp(prompt: followUp.prompt, pendingDraft: draft)
            next.messages.append(.init(
                sender: .bot,
                kind: .text("Before I file this — \(followUp.prompt) (Tap Skip if you'd rather not say.)")
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_escalation_followup_asked",
                // "(category)" distinguishes a catch-all question from an entry's
                // own, so the two can be compared for answer rate later.
                parameters: ["entry_id": entryFollowUp != nil ? (entryId ?? "(none)") : "(category)"]
            )))
        } else {
            next.step = .drafting(ticket: draft)
            // PP-4843: arm the send-consent gate — the patron must be shown to
            // have seen this fresh preview (.ticketPreviewPresented) before a
            // confirm is honored.
            next.pendingSendConsent = true
            next.messages.append(.init(
                sender: .bot,
                kind: .text("I haven't seen exactly that before — let me file a ticket so support can look. Here's what I'll send:")
            ))
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
        }
        effects.append(.emitTelemetry(.init(name: "triage_escalate_\(tagSuffix.replacingOccurrences(of: "-", with: "_"))")))
    }

    /// Escalation path used when a guided-flow attempt either exhausts all
    /// steps or the user abandons mid-flow. Attaches the full
    /// ResolutionTrace to the TicketDraft so support sees exactly what was
    /// tried, in what order, and how long the user spent.
    private func escalateWithTrace(
        state next: inout ConversationState,
        effects: inout [ConversationEffect],
        userText: String,
        category: KBCategory,
        matchedEntryId: String,
        trace: ResolutionTrace,
        helpspotTag: String,
        tagSuffix: String
    ) {
        let draft = TicketDraft(
            // PP-4805: redact patron-typed free text at draft assembly.
            userDescription: redactor.redactLine(userText),
            category: category,
            matchedEntryId: matchedEntryId,
            context: next.context ?? emptyContext(),
            helpspotTags: [helpspotTag, "guided-flow-\(trace.outcome.rawValue)"],
            priority: .normal,
            resolutionTrace: trace,
            omittedFields: initialOmittedFields(next.context)
        )
        // Same follow-up gate as transitionToDrafting — if the entry has
        // an escalationFollowUp, ask it first; otherwise go straight to
        // the ticket preview. Acknowledgment text leads either way so the
        // chat reads naturally.
        // Same fallback as askEscalationFollowUpOrDraft: prefer the entry's own
        // question, else the category's catch-all. Without this, an entry with
        // steps but no follow-up walked the patron through a whole flow and then
        // filed with nothing asked — the blank-ticket class, surviving on the one
        // path where the patron had invested the most effort.
        let entryFollowUp = knowledgeBase.entry(id: matchedEntryId)?.escalationFollowUp
        if let followUp = entryFollowUp ?? knowledgeBase.categoryFollowUp(for: draft.category) {
            next.step = .awaitingEscalationFollowUp(prompt: followUp.prompt, pendingDraft: draft)
            // "That didn't resolve it" is only true if they tried something. When
            // every step was skipped because the patron had already done it, the
            // trace is empty and asserting a failed attempt reads as the bot not
            // following its own conversation — one line after it demonstrated
            // that it was. Found by driving the app; the reducer tests assert
            // state, not prose, so it was invisible to them.
            let attemptedSomething = !trace.attempts.isEmpty
            let preamble = attemptedSomething
                ? "That didn't resolve it. Before I file the ticket — "
                : "Before I file the ticket — "
            next.messages.append(.init(
                sender: .bot,
                kind: .text("\(preamble)\(followUp.prompt) (Tap Skip if you'd rather not say.)")
            ))
            effects.append(.emitTelemetry(.init(
                name: "triage_escalation_followup_asked",
                parameters: ["entry_id": entryFollowUp != nil ? matchedEntryId : "(category)"]
            )))
        } else {
            next.step = .drafting(ticket: draft)
            // PP-4843: arm the send-consent gate for this fresh preview too.
            next.pendingSendConsent = true
            next.messages.append(.init(
                sender: .bot,
                kind: .text("That didn't fix it. I'll file a ticket with the exact steps you tried so support can pick up where we left off.")
            ))
            next.messages.append(.init(sender: .bot, kind: .ticketPreview(draft)))
        }
        effects.append(.emitTelemetry(.init(
            name: "triage_escalate_\(tagSuffix.replacingOccurrences(of: "-", with: "_"))",
            parameters: [
                "entry_id": matchedEntryId,
                "attempts_count": String(trace.attempts.count),
                "outcome": trace.outcome.rawValue
            ]
        )))
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
    /// Persist (or, with nil, clear) the pending draft so a failed submission
    /// survives to the next chat open. Host writes to a PendingDraftStore.
    case persistPendingDraft(TicketDraft?)
    /// Ask the host to load any persisted pending draft and, if present,
    /// dispatch `.restorePendingDraft`. Emitted on `.start` (PP-4808).
    case loadPendingDraft
    /// ViewModel hands this off to the wired FallbackClassifier
    /// (ClaudeFallbackClassifier in production). On success it dispatches
    /// `.aiFallbackResolved`, on any failure mode `.aiFallbackUnavailable`.
    /// userText is the pre-sanitized version — sanitization happens inside
    /// the classifier per the contract on `FallbackClassifier`.
    case runAIFallback(userText: String, category: KBCategory?, context: ContextSnapshot?)
}
