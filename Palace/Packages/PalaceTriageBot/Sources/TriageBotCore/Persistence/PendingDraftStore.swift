import Foundation

/// Serializes a pending TicketDraft so a submission that fails on one chat
/// session can be re-offered on the next (PP-4808). Pure Foundation JSON —
/// the draft graph (context + trace + follow-up) is fully Codable.
public enum PendingDraftCodec {
    // Internal persistence blob — not an external contract, so it uses the
    // default `.deferredToDate` date strategy, which round-trips Date exactly
    // (ISO8601 would truncate sub-second precision and break draft equality on
    // re-offer).
    public static func encode(_ draft: TicketDraft) -> Data? {
        try? JSONEncoder().encode(draft)
    }

    public static func decode(_ data: Data) -> TicketDraft? {
        try? JSONDecoder().decode(TicketDraft.self, from: data)
    }
}

/// Persists at most one pending draft. The reducer emits
/// `.persistPendingDraft(draft?)` (nil clears) and `.loadPendingDraft`; the
/// ViewModel routes those to this store. Kept a protocol so tests inject an
/// in-memory double and the iOS host backs it with UserDefaults.
public protocol PendingDraftStore: Sendable {
    /// Save the draft, or clear the slot when passed nil.
    func save(_ draft: TicketDraft?)
    /// The last-saved draft, or nil if none / decode failed.
    func load() -> TicketDraft?
}

/// UserDefaults-backed store. Foundation-only (no UIKit) so it lives in Core
/// and is testable under macOS `swift test`.
public final class UserDefaultsPendingDraftStore: PendingDraftStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "triagebot.pendingDraft") {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ draft: TicketDraft?) {
        guard let draft, let data = PendingDraftCodec.encode(draft) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    public func load() -> TicketDraft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return PendingDraftCodec.decode(data)
    }
}
