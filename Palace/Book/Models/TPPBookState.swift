import Foundation

let DownloadingKey = "downloading"
let DownloadFailedKey = "download-failed"
let DownloadNeededKey = "download-needed"
let DownloadSuccessfulKey = "download-successful"
let UnregisteredKey = "unregistered"
let HoldingKey = "holding"
let UsedKey = "used"
let UnsupportedKey = "unsupported"
let ReturningKey = "returning"
let SAMLStartedKey = "saml-started"

@objc public enum TPPBookState: Int, CaseIterable, Sendable {
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

    init?(_ stringValue: String) {
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
        case SAMLStartedKey:
            self = .SAMLStarted
        default:
            return nil
        }
    }

    func stringValue() -> String {
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

// MARK: - Recommended state transition contract
//
// TPPBookRegistry.setState currently writes any state without validation —
// this table documents the *recommended* transitions for the book lifecycle.
// It is exposed so tests (e.g. PalaceCheck property tests) can pin a contract
// and so future enforcement at the setState seam is a one-line opt-in.
//
// Adding a transition here is a docs change, not a behavior change.
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
        // From .used
        .init(from: .used, to: .downloadSuccessful),
        .init(from: .used, to: .returning),
        .init(from: .used, to: .unregistered),
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

    /// Returns `true` if the transition from `from` to `to` is documented as
    /// allowed. Self-transitions are always allowed.
    ///
    /// **Note:** This is currently a *documentation* contract. `TPPBookRegistry.setState`
    /// does not yet enforce it. Tests use this to pin the intended state machine
    /// so that future enforcement is a one-line opt-in at the setState seam.
    static func canTransition(from: TPPBookState, to: TPPBookState) -> Bool {
        if from == to { return true }
        return allowedTransitions.contains(.init(from: from, to: to))
    }
}

// For Objective-C, since Obj-C enum is not allowed to have methods
// TODO: Remove when migration to Swift completed
class TPPBookStateHelper: NSObject {
    @objc(stringValueFromBookState:)
    static func stringValue(from state: TPPBookState) -> String {
        return state.stringValue()
    }

    @objc(bookStateFromString:)
    static func bookState(fromString string: String) -> NSNumber? {
        guard let state = TPPBookState(string) else {
            return nil
        }

        return NSNumber(integerLiteral: state.rawValue)
    }

    @objc static func allBookStates() -> [TPPBookState.RawValue] {
        return TPPBookState.allCases.map { $0.rawValue }
    }
}
