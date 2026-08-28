import Foundation

public let DownloadingKey = "downloading"
public let DownloadFailedKey = "download-failed"
public let DownloadNeededKey = "download-needed"
public let DownloadSuccessfulKey = "download-successful"
public let UnregisteredKey = "unregistered"
public let HoldingKey = "holding"
public let UsedKey = "used"
public let UnsupportedKey = "unsupported"
public let ReturningKey = "returning"
public let SAMLStartedKey = "saml-started"

public enum TPPBookState: Int, CaseIterable, Sendable {
    case unregistered = 0
    case downloadNeeded = 1
    case downloading
    case downloadFailed
    case downloadSuccessful
    case returning
    case holding
    case used
    case unsupported
    // This state means that user is logged using SAML environment and app begun download process, but didn't transition to download center yet
    case SAMLStarted

    public init?(_ stringValue: String) {
        switch stringValue {
        case DownloadingKey:
            self = .downloading
        case DownloadFailedKey:
            self = .downloadFailed
        case DownloadNeededKey:
            self = .downloadNeeded
        case DownloadSuccessfulKey:
            self = .downloadSuccessful
        case UnregisteredKey:
            self = .unregistered
        case HoldingKey:
            self = .holding
        case UsedKey:
            self = .used
        case UnsupportedKey:
            self = .unsupported
        case ReturningKey:
            self = .returning
        case SAMLStartedKey:
            self = .SAMLStarted
        default:
            return nil
        }
    }

    public func stringValue() -> String {
        switch self {
        case .downloading:
            return DownloadingKey
        case .downloadFailed:
            return DownloadFailedKey
        case .downloadNeeded:
            return DownloadNeededKey
        case .downloadSuccessful:
            return DownloadSuccessfulKey
        case .unregistered:
            return UnregisteredKey
        case .holding:
            return HoldingKey
        case .used:
            return UsedKey
        case .unsupported:
            return UnsupportedKey
        case .returning:
            return ReturningKey
        case .SAMLStarted:
            return SAMLStartedKey
        }
    }
}

// MARK: - Enforced state transition contract
//
// This table is the declared legal-transition set for the book lifecycle and is
// ENFORCED at the single mutation seam `TPPBookRegistry.setState` via
// `canTransition` (swarm_8ce6f5ae WS3 / state-management doctrine): a transition
// not listed here trips an `assertionFailure` in DEBUG and a telemetry log in
// RELEASE — but the transition is STILL applied (state is never dropped).
//
// Because the seam now enforces this set, ADDING a transition here IS a behavior
// change (it legalizes a path that previously asserted); removing one makes a
// live path illegal. Keep it in sync with the real call sites.
public extension TPPBookState {

    /// All transitions the book lifecycle is documented to allow.
    /// `(from, to)` pairs. Idempotent self-transitions are always allowed
    /// and are NOT listed here.
    static let allowedTransitions: Set<TransitionPair> = [
        // From .unregistered
        .init(from: .unregistered, to: .holding),
        .init(from: .unregistered, to: .downloadNeeded),
        .init(from: .unregistered, to: .downloading),
        .init(from: .unregistered, to: .unsupported),
        // From .holding
        .init(from: .holding, to: .unregistered),
        .init(from: .holding, to: .downloadNeeded),
        // A ready hold stays `.holding` and renders "Get"; when the
        // concurrent-download cap is hit, `enqueuePending` promotes it straight
        // to `.downloading` (DownloadQueueOrchestrator.swift:91, reached via
        // DownloadStartCoordinator.swift:278 which lets `.holding` proceed).
        .init(from: .holding, to: .downloading),
        // From .downloadNeeded
        .init(from: .downloadNeeded, to: .downloading),
        .init(from: .downloadNeeded, to: .SAMLStarted),
        .init(from: .downloadNeeded, to: .unregistered),
        .init(from: .downloadNeeded, to: .downloadFailed),
        // From .downloading
        .init(from: .downloading, to: .downloadSuccessful),
        .init(from: .downloading, to: .downloadFailed),
        .init(from: .downloading, to: .downloadNeeded),
        .init(from: .downloading, to: .SAMLStarted),
        .init(from: .downloading, to: .unregistered),
        // From .downloadFailed
        .init(from: .downloadFailed, to: .downloadNeeded),
        .init(from: .downloadFailed, to: .downloading),
        .init(from: .downloadFailed, to: .unregistered),
        // From .downloadSuccessful
        .init(from: .downloadSuccessful, to: .used),
        .init(from: .downloadSuccessful, to: .returning),
        .init(from: .downloadSuccessful, to: .unregistered),
        // Content-protection re-download (ReaderService.swift:585), OverDrive
        // `-1008` signed-URL recovery which resets to `.downloadNeeded` first
        // (AudiobookSessionManager.swift:2227), and LRU disk eviction
        // (DiskBudgetManager.swift:168) all legitimately walk a completed book
        // back to `.downloadNeeded`.
        .init(from: .downloadSuccessful, to: .downloadNeeded),
        // From .used
        .init(from: .used, to: .downloadSuccessful),
        .init(from: .used, to: .returning),
        .init(from: .used, to: .unregistered),
        // Same re-download / eviction paths as above can fire while a book sits
        // in `.used` (ReaderService.swift:585, AudiobookSessionManager.swift:2227,
        // DiskBudgetManager.swift:168).
        .init(from: .used, to: .downloadNeeded),
        // From .returning
        .init(from: .returning, to: .unregistered),
        .init(from: .returning, to: .downloadFailed),
        // From .SAMLStarted
        .init(from: .SAMLStarted, to: .downloading),
        .init(from: .SAMLStarted, to: .downloadFailed),
        .init(from: .SAMLStarted, to: .downloadNeeded),
        .init(from: .SAMLStarted, to: .unregistered),
        // From .unsupported
        .init(from: .unsupported, to: .unregistered),
    ]

    /// Hashable transition pair for use in `allowedTransitions`.
    struct TransitionPair: Hashable, Sendable {
        public let from: TPPBookState
        public let to: TPPBookState
        public init(from: TPPBookState, to: TPPBookState) {
            self.from = from
            self.to = to
        }
    }

    /// Returns `true` if the transition from `from` to `to` is allowed.
    /// Self-transitions are always allowed.
    ///
    /// Consulted by `TPPBookRegistry.setState` on every state mutation: a `false`
    /// result routes through the registry's illegal-transition handler (assert in
    /// DEBUG, log in RELEASE) without dropping the write.
    static func canTransition(from: TPPBookState, to: TPPBookState) -> Bool {
        if from == to { return true }
        return allowedTransitions.contains(.init(from: from, to: to))
    }
}
