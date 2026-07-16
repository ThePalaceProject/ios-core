import Foundation

/// One turn in the conversation log. Kept simple — the UI is responsible for
/// rendering rich elements (chips, KB cards) by inspecting the `kind`.
public struct ConversationMessage: Equatable, Identifiable, Sendable {
    public enum Sender: Equatable, Sendable {
        case bot
        case user
    }

    public enum Kind: Equatable, Sendable {
        case text(String)
        case categoryChips
        case kbMatch(entryId: String)
        /// One step in a guided troubleshooting flow. Renders the step's
        /// instruction + check question + Yes/No buttons.
        case guidedStep(entryId: String, stepIndex: Int)
        case ticketPreview(TicketDraft)
        case ticketReceipt(TicketReceipt)
        /// Terminal-but-recoverable submission failure. Renders Retry / Copy
        /// details / Start over. Carries the failed draft (nil only if the
        /// draft was somehow lost) so Retry re-submits the exact ticket and
        /// Copy details can reconstruct it (PP-4808).
        case errorActions(draft: TicketDraft?)
    }

    public let id: UUID
    public let sender: Sender
    public let kind: Kind
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        sender: Sender,
        kind: Kind,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// Top-level conversation state. The reducer mutates this; the UI observes it.
public struct ConversationState: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case welcome
        case awaitingCategory
        case awaitingDescription(category: KBCategory)
        case awaitingFollowUp(category: KBCategory, candidate: String)
        /// Local classifier escalated AND the AI fallback is wired — the
        /// reducer is waiting for ClaudeFallbackClassifier to weigh in
        /// before deciding whether to surface a KB match or escalate
        /// straight to a ticket draft. Bot shows a thinking indicator
        /// during this state.
        case awaitingAIClassification(userText: String, category: KBCategory?)
        case matched(entryId: String)
        /// User is walking through a multi-step resolution flow for this
        /// entry. `stepIndex` is the current step in `entry.userFacingSteps`.
        /// `attempts` accumulates every Yes/No into a trace that's attached
        /// to the escalation ticket if all steps fail.
        case guidedStep(entryId: String, stepIndex: Int, startedAt: Date, attempts: [StepAttempt])
        /// Bot is asking the user a specific follow-up question right
        /// before filing an escalation ticket ("Which library?", "Which
        /// book title?"). The user's reply or skip becomes
        /// `TicketDraft.escalationFollowUp` so support sees the
        /// structured context immediately. `pendingDraft` is the
        /// almost-final ticket — we only add the follow-up answer
        /// before transitioning to .drafting.
        case awaitingEscalationFollowUp(prompt: String, pendingDraft: TicketDraft)
        case drafting(ticket: TicketDraft)
        case submitting(ticket: TicketDraft)
        case sent(receipt: TicketReceipt)
        /// A real submission failure. Carries the friendly message AND the
        /// failed draft so the user can Retry the exact ticket, Copy its
        /// details, or Start over — never a dead end (PP-4808).
        case error(message: String, failedDraft: TicketDraft?)
    }

    public var step: Step
    public var messages: [ConversationMessage]
    public var context: ContextSnapshot?
    public var lastClassification: ClassificationResult?
    public var inputText: String

    public init(
        step: Step = .welcome,
        messages: [ConversationMessage] = [],
        context: ContextSnapshot? = nil,
        lastClassification: ClassificationResult? = nil,
        inputText: String = ""
    ) {
        self.step = step
        self.messages = messages
        self.context = context
        self.lastClassification = lastClassification
        self.inputText = inputText
    }
}

/// All user / system events the reducer responds to.
public enum ConversationAction: Equatable, Sendable {
    case start                                  // VC appeared; load KB + context
    case contextLoaded(ContextSnapshot)
    case userTappedCategory(KBCategory)
    case userTypedDescription(String)
    case userSubmittedDescription
    case userAnsweredFollowUp(yes: Bool)
    case userTappedNotifyMeOnFix(entryId: String)
    case userTappedFileTicketAnyway
    case userTappedDismiss
    /// User opted into the guided troubleshooting flow from the KB match
    /// card. Reducer transitions to `.guidedStep(entryId, 0, ...)`.
    case userTappedStartGuidedFlow(entryId: String)
    /// User confirmed the current step fixed their issue. Reducer records
    /// the resolved StepAttempt and transitions to a friendly close-out.
    case userConfirmedStepResolved(stepId: String)
    /// User confirmed the current step did NOT fix their issue. Reducer
    /// either advances to the next step or, if exhausted, escalates with
    /// the full ResolutionTrace attached.
    case userConfirmedStepDidNotResolve(stepId: String)
    /// User picked a specific response on a step with explicit
    /// `responses` defined. Reducer routes by the response's
    /// `outcome` (resolved / advance / escalate) — semantically richer
    /// than the legacy binary Yes/No, which assumes every "yes" means
    /// "the whole issue is fixed."
    case userSelectedStepResponse(stepId: String, responseIndex: Int)
    /// User submitted their answer to the escalation follow-up question
    /// (or tapped Skip — `answer == nil`). Reducer merges the answer
    /// into the pending draft and transitions to `.drafting`.
    case userAnsweredEscalationFollowUp(answer: String?)
    /// User abandoned the guided flow (e.g. tapped "skip to summary" or
    /// "just file a ticket" mid-walkthrough). Reducer records the trace
    /// with outcome=abandoned and escalates.
    case userTappedAbandonGuidedFlow
    case userConfirmedTicketSubmit
    case userCancelledTicketSubmit
    case ticketSubmitted(TicketReceipt)
    /// Submission didn't complete. Carries a structured `SubmissionFailure`
    /// so the reducer can distinguish a user cancel (restore the preview)
    /// from a real transport failure (offer Retry / Copy / Start over and
    /// persist the draft). Replaces the old raw-string form (PP-4808).
    case ticketSubmissionFailed(SubmissionFailure)
    /// User tapped Retry on the error card — re-submit the failed draft.
    case userTappedRetrySubmission
    /// User tapped Start over on the error card — reset to category chips
    /// and clear any persisted pending draft.
    case userTappedStartOver
    /// Host loaded a draft persisted from a prior failed session and is
    /// re-offering it (PP-4808). Reducer restores the preview.
    case restorePendingDraft(TicketDraft)
    case inputChanged(String)
    /// AI fallback returned a classification. Reducer routes to .matched
    /// or .drafting based on the decision.
    case aiFallbackResolved(ClassificationResult)
    /// AI fallback couldn't run (offline, timeout, error, disabled). Reducer
    /// falls through to the standard escalate path.
    case aiFallbackUnavailable
}
