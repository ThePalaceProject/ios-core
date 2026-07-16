import Foundation

/// The complete, enumerable set of parameter keys the triage bot is allowed to
/// attach to a ``TelemetryEvent``. Every value behind these keys is an id, a
/// count, or an enum `rawValue` — **never** free text (a user-typed symptom
/// description, an email address, a library barcode). Because the key space is a
/// finite enum, a reviewer can audit exactly what leaves the device, and
/// ``TelemetryContract`` drops any key not listed here before an event reaches an
/// analytics backend.
///
/// Keep this list in sync with the reducer: every key emitted by
/// `ConversationReducer` must have a case here. `TelemetryContractTests` drives
/// the reducer and asserts the union of emitted keys is a subset of this enum, so
/// a new free-text parameter — or a stale enum — fails a unit test.
public enum TelemetryParameterKey: String, CaseIterable, Sendable {
    case category
    case entryId = "entry_id"
    case confidence
    case candidateCount = "candidate_count"
    case stepId = "step_id"
    case stepCount = "step_count"
    case stepsAttempted = "steps_attempted"
    case nextIndex = "next_index"
    case priority
    case ticketId = "ticket_id"
    case attemptsCount = "attempts_count"
    case outcome
}

/// Enforcement point for the "no free text in telemetry" contract. The production
/// (Firebase) sink forwards **only** the parameters this returns, so a free-text
/// parameter can never reach an analytics backend even if a future caller adds one.
public enum TelemetryContract {

    /// Keeps only the parameters whose key is part of the enumerable contract
    /// (``TelemetryParameterKey``). Any other key is dropped.
    public static func enumerableParameters(of event: TelemetryEvent) -> [String: String] {
        event.parameters.filter { TelemetryParameterKey(rawValue: $0.key) != nil }
    }

    /// The parameter keys on `event` that are **not** part of the enumerable
    /// contract. Empty for every event the bot emits today; a non-empty result
    /// means a caller introduced a key that must either be added to
    /// ``TelemetryParameterKey`` (if it is genuinely an id/count/enum) or removed
    /// (if it is free text).
    public static func nonEnumerableKeys(of event: TelemetryEvent) -> [String] {
        event.parameters.keys
            .filter { TelemetryParameterKey(rawValue: $0) == nil }
            .sorted()
    }
}
