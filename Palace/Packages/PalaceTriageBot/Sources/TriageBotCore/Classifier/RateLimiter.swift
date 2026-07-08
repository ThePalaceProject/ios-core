import Foundation

/// Sliding-window rate limiter for the AI fallback. Two limits:
///
///   - **Per-minute**: caps burst cost. Default 10 calls/min — even if every
///     interaction triggers fallback, daily spend stays bounded.
///   - **Per-session**: caps total cost for a single chat session.
///     Default 100 calls/session — far more than any honest user would
///     need; protects against pathological loops (e.g. UI bug that
///     re-submits the same query in a tight loop).
///
/// When either limit is reached, `record()` returns false and the caller
/// (ClaudeFallbackClassifier) should throw `FallbackError.rateLimited`,
/// which the ViewModel translates to `.aiFallbackUnavailable` — the user
/// silently falls through to local-only escalate, no error dialog.
///
/// Lives in TriageBotCore (not TriageBotIOS) so it's testable without
/// network and reusable by any future fallback transport.
public final class FallbackRateLimiter: @unchecked Sendable {

    public struct Limits: Equatable, Sendable {
        public let maxCallsPerMinute: Int
        public let maxCallsPerSession: Int

        public init(maxCallsPerMinute: Int = 10, maxCallsPerSession: Int = 100) {
            self.maxCallsPerMinute = maxCallsPerMinute
            self.maxCallsPerSession = maxCallsPerSession
        }
    }

    private let limits: Limits
    private let lock = NSLock()
    private let nowProvider: @Sendable () -> Date
    private var callTimestamps: [Date] = []
    private var sessionCount: Int = 0

    /// - Parameters:
    ///   - limits: per-minute + per-session caps. Defaults to conservative
    ///     values appropriate for a small-team demo build.
    ///   - now: injectable clock for deterministic tests.
    public init(
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limits = limits
        self.nowProvider = now
    }

    /// Record a new call attempt. Returns `true` if the call is within both
    /// limits (caller should proceed), `false` if either limit would be
    /// exceeded (caller should fail fast). Stateful — every call advances
    /// the internal counter, so don't call this for "would-it-be-allowed"
    /// checks without consuming the slot.
    public func record() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if sessionCount >= limits.maxCallsPerSession {
            return false
        }

        let now = nowProvider()
        let cutoff = now.addingTimeInterval(-60)
        callTimestamps.removeAll { $0 < cutoff }

        if callTimestamps.count >= limits.maxCallsPerMinute {
            return false
        }

        callTimestamps.append(now)
        sessionCount += 1
        return true
    }

    /// Resets the per-session counter. Sliding window is unaffected. Call
    /// this when the chat session ends (e.g. SupportChatView dismissed)
    /// so a fresh conversation gets a fresh session budget.
    public func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        sessionCount = 0
    }
}
