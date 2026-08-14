import Foundation

/// One step in a guided troubleshooting flow. KB entries that opt in to
/// step-by-step resolution define an ordered list of these; the bot walks
/// the user through them one at a time, asking after each "did this work?",
/// advancing to the next step on "no" and recording a `StepAttempt` either
/// way.
///
/// **Why opt-in not mandatory.** The old single-card "here's the workaround"
/// flow remains valid for entries where the fix is genuinely one-shot (e.g.
/// a UI affordance the user just needs to be told about — "tap the field
/// anyway, it IS active"). Entries that benefit from iteration (audiobook
/// playback, downloads, etc.) opt in by populating `userFacingSteps`. KB
/// curators decide per-entry.
///
/// **Why each step has a diagnostic tag.** Telemetry per step is the
/// long-term value of this design: support sees "step 2 resolves 73% of
/// KI-001 cases" instead of "KI-001 had a workaround." That data drives
/// KB tuning + product fixes (if step 3 of every KI is "sign out and back
/// in", that's a deeper auth problem).
public struct KBStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// What the user should do. Imperative, short, no jargon.
    public let instruction: String
    /// The follow-up question. Should be answerable by one of the
    /// `responses` below.
    public let check: String
    /// Optional explicit response options. When provided, the UI renders
    /// these labels (instead of generic "Still broken / Fixed it") AND
    /// the reducer routes by each response's `outcome` — diagnostic
    /// intermediate steps can map a "yes" to `.advance` (proceed to the
    /// next step) rather than always meaning `.resolved`. When nil, the
    /// UI falls back to the legacy Yes/No pair (treating Yes as
    /// `.resolved` and No as `.advance`/`.escalate` per step position).
    public let responses: [KBStepResponse]?
    /// Optional telemetry tag — emitted on resolved + not-resolved events
    /// so support can see per-step success rates without naming-convention
    /// guessing later.
    public let diagnostic: String?
    /// Which remedy this step asks the patron to perform, if it is one of the
    /// common ones they often try before contacting support. Lets the reducer
    /// skip a step the patron has already told us they did, rather than asking
    /// them to reinstall for the third time. Nil for steps that are not a
    /// standard remedy (e.g. "tap the field anyway, it IS active").
    let remedy: Remedy?

    enum CodingKeys: String, CodingKey {
        case id, instruction, check, responses, diagnostic, remedy
    }

    public init(
        id: String,
        instruction: String,
        check: String,
        responses: [KBStepResponse]? = nil,
        diagnostic: String? = nil,
        remedy: Remedy? = nil
    ) {
        self.id = id
        self.instruction = instruction
        self.check = check
        self.responses = responses
        self.diagnostic = diagnostic
        self.remedy = remedy
    }
}

/// One answer the user can give to a step's check question. Carries both
/// the patron-facing label AND the semantic meaning the reducer needs to
/// pick the right next state.
public struct KBStepResponse: Codable, Equatable, Sendable {
    /// What the user sees on the button. Should answer the step's check
    /// in patron-natural language ("Yes, list appeared", "No, still
    /// broken", "Crashes a different way now").
    public let label: String
    /// What this answer means for the state machine.
    public let outcome: Outcome
    /// Optional per-response telemetry tag — separates "step 1 answered
    /// 'list appeared'" from "step 1 answered 'never saw a list'" so
    /// support sees which branch each user took, not just resolved-vs-not.
    public let diagnostic: String?

    public enum Outcome: String, Codable, Sendable {
        /// User's issue is fixed. Close out, record success.
        case resolved
        /// Step did its job but we're not done — try the next step.
        /// (Diagnostic intermediate steps where "yes" doesn't mean the
        /// whole issue is fixed.)
        case advance
        /// Skip remaining steps and file a ticket. Attaches the trace
        /// so support sees what was tried.
        case escalate
        /// This step does not apply to me — move on without counting it as an
        /// attempt. Advances exactly like `advance`; the difference is only in
        /// what the trace records, which is the whole point.
        case notApplicable = "not_applicable"
    }

    public init(label: String, outcome: Outcome, diagnostic: String? = nil) {
        self.label = label
        self.outcome = outcome
        self.diagnostic = diagnostic
    }
}

/// One step the user worked through during a guided resolution flow.
/// Accumulates into a trace that's attached to the escalation ticket when
/// all steps fail to resolve the issue.
public struct StepAttempt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case resolved
        case didNotResolve = "did_not_resolve"
        case abandoned
        /// The step did not apply to this patron, so nothing was attempted —
        /// "check the App Store for an update" answered by someone already on
        /// the newest build.
        ///
        /// Distinct from `didNotResolve` because the re-ranking rule reads these
        /// traces to rate a rung, and folding a non-attempt into the failure
        /// count deflates that rate with something that never happened.
        case notApplicable = "not_applicable"
    }

    public let stepId: String
    public let outcome: Outcome
    public let timestamp: Date

    public init(stepId: String, outcome: Outcome, timestamp: Date) {
        self.stepId = stepId
        self.outcome = outcome
        self.timestamp = timestamp
    }
}

/// The full record of a guided resolution attempt. Attached to the
/// escalation `TicketDraft` so support sees exactly what the user tried
/// before giving up — turns "couldn't fix it" into "tried steps 1, 2, 3,
/// none worked, here's the timing." That's the difference between a triage
/// minute and a debug hour for the engineer.
public struct ResolutionTrace: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// User confirmed a step fixed the issue. Trace recorded for telemetry.
        case resolved
        /// All steps tried, none worked. Escalating with trace.
        case escalatedAfterStepsExhausted = "escalated_after_steps_exhausted"
        /// User abandoned the flow mid-way (left chat, picked another
        /// category, etc.). Trace recorded for telemetry only.
        case abandoned
    }

    public let entryId: String
    public let attempts: [StepAttempt]
    public let startedAt: Date
    public let endedAt: Date
    public let outcome: Outcome

    public init(
        entryId: String,
        attempts: [StepAttempt],
        startedAt: Date,
        endedAt: Date,
        outcome: Outcome
    ) {
        self.entryId = entryId
        self.attempts = attempts
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }
}
