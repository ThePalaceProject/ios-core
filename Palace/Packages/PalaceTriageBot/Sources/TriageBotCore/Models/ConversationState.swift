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
        case drafting(ticket: TicketDraft)
        case submitting(ticket: TicketDraft)
        case sent(receipt: TicketReceipt)
        case error(message: String)
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
    /// User abandoned the guided flow (e.g. tapped "skip to summary" or
    /// "just file a ticket" mid-walkthrough). Reducer records the trace
    /// with outcome=abandoned and escalates.
    case userTappedAbandonGuidedFlow
    case userConfirmedTicketSubmit
    case userCancelledTicketSubmit
    case ticketSubmitted(TicketReceipt)
    case ticketSubmissionFailed(String)
    case inputChanged(String)
    /// AI fallback returned a classification. Reducer routes to .matched
    /// or .drafting based on the decision.
    case aiFallbackResolved(ClassificationResult)
    /// AI fallback couldn't run (offline, timeout, error, disabled). Reducer
    /// falls through to the standard escalate path.
    case aiFallbackUnavailable
}
