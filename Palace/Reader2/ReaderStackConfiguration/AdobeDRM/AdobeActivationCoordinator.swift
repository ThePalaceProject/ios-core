//
//  AdobeActivationCoordinator.swift
//  The Palace Project
//
//  Single-flight coordinator for Adobe RMSDK device activation (PP-4952).
//  RMSDK is not safe to call concurrently: two racing borrows both entering
//  `authorizeWithVendorID:` corrupted its heap and crashed in its expat parser
//  (Crashlytics ed05e903). Concurrent callers coalesce onto one activation.
//  Not gated on `FEATURE_DRM_CONNECTOR`: there is no RMSDK dependency here, so
//  it compiles for Palace-noDRM and stays directly testable.
//

import Foundation

/// The narrow slice of the user account that borrow-time Adobe activation needs.
///
/// Keeps concurrency tests off the real keychain and off `TPPUserAccount`'s
/// blocking `accountInfoQueue.sync`, which would tie up cooperative-pool
/// threads.
protocol AdobeActivationAccount: AnyObject, Sendable {
    var userID: String? { get }
    var deviceID: String? { get }
    var licensor: [String: Any]? { get }
    func setUserID(_ id: String)
    func setDeviceID(_ id: String)
    /// Persists a licensor refreshed at activation time (PP-3649). The
    /// keychain copy is written at sign-in and never updated otherwise, which
    /// is how a 60-minute token reaches Adobe hours stale.
    func setLicensor(_ licensor: [String: Any])
}

extension TPPUserAccount: AdobeActivationAccount {}

/// Serializes Adobe device activation so at most one activation is ever in
/// flight, no matter how many callers ask for one.
///
/// Modeled on `TokenRefreshCoordinator` in `TPPNetworkExecutor`.
///
/// This type does single-flight only; bounding the work is the caller's job.
/// A task-group timeout here would not help: a task group awaits every child
/// on exit, and the RMSDK continuation may never resume, so `inFlight` would
/// never clear and every later borrow would coalesce onto a dead task. The
/// deadline lives on the continuation in `AdobeDRMService.ensureDeviceActivated`.
actor AdobeActivationCoordinator {

    /// Ceiling a caller should apply to a single activation: generous for a slow
    /// connection while still letting a patron retry past a wedge.
    static let defaultTimeout: TimeInterval = 90

    /// The activation currently in flight, if any. Non-nil only between the
    /// moment a caller claims the slot and the moment that caller's `activate`
    /// returns.
    private var inFlight: Task<Void, Error>?

    /// Number of times the slot was actually claimed — i.e. how many times the
    /// underlying RMSDK `authorize` really ran. Callers that coalesce behind an
    /// in-flight activation do not increment this.
    private(set) var activationAttemptCount = 0

    /// How many callers coalesced onto an already-in-flight activation, i.e.
    /// how many concurrent borrows this gate kept out of Adobe's RMSDK.
    private(set) var coalescedCount = 0

    /// Runs `work` unless an activation is already in flight, in which case the
    /// caller awaits the in-flight result instead of starting a second one.
    ///
    /// Failure is shared: every coalesced caller sees the same error, since
    /// per-waiter retries would reintroduce concurrent RMSDK entry. Callers
    /// retry at the borrow level.
    ///
    /// A caller that arrives in the narrow window after the work finished but
    /// before the owner resumed will receive the just-computed result rather
    /// than starting a fresh activation. That is correct for success (the
    /// device is now activated) and safe for failure (the caller sees an error
    /// and can retry, having cost RMSDK nothing).
    func activate(_ work: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            coalescedCount += 1
            return try await inFlight.value
        }

        activationAttemptCount += 1

        // Detached so the RMSDK call is not pinned to this actor's executor and
        // cannot re-enter it.
        let task = Task.detached(priority: .userInitiated) { try await work() }

        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

}
