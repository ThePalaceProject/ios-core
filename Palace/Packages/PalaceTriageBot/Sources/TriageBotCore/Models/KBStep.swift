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
    /// The follow-up question that gates Yes/No. Short.
    public let check: String
    /// Optional telemetry tag — emitted on resolved + not-resolved events
    /// so support can see per-step success rates without naming-convention
    /// guessing later.
    public let diagnostic: String?

    public init(id: String, instruction: String, check: String, diagnostic: String? = nil) {
        self.id = id
        self.instruction = instruction
        self.check = check
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
