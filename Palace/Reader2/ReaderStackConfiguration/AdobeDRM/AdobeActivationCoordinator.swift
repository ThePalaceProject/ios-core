//
//  AdobeActivationCoordinator.swift
//  The Palace Project
//
//  Single-flight coordinator for Adobe RMSDK device activation.
//
//  WHY THIS EXISTS — Crashlytics `ed05e903c2777582d68747b624e4f548`, first seen
//  in 3.2.3 (492). Adobe's RMSDK is legacy C++ and is not safe to call
//  concurrently. `AdobeDRMService.ensureDeviceActivated()` had no in-flight
//  de-duplication: its only guard was the `isUserAuthorized` fast path, which
//  cannot be true until a prior activation has already COMPLETED. Two borrows
//  racing (a double tap, a retry, two entry points) therefore both entered
//  `-[NYPLADEPT authorizeWithVendorID:...]`, corrupted the shared C++ heap, and
//  the process aborted inside RMSDK's bundled expat parser:
//
//      _xzm_xzone_malloc_from_freelist_chunk.cold.1
//      lookup / storeAtts / XML_ParseBuffer
//      adept::createActivationDOM → adept::DRMProcessorImpl::getActivations()
//
//  The reporting device's log showed the same borrow starting twice 2.3s apart,
//  each logging "Performing on-demand Adobe device activation for borrow".
//
//  This actor collapses concurrent callers onto ONE underlying activation: the
//  first caller claims the slot and runs the work, everyone else awaits that
//  same result. See PP-4952.
//
//  Deliberately NOT gated on `#if FEATURE_DRM_CONNECTOR` — the coalescing logic
//  has no RMSDK dependency, so it compiles for Palace-noDRM too and stays
//  directly testable.
//

import Foundation

/// The narrow slice of the user account that borrow-time Adobe activation needs.
///
/// Depending on this rather than the concrete `TPPUserAccount` keeps the
/// concurrency tests off the real keychain, per the CLAUDE.md rule that tests
/// never touch real singletons or keychain state. It also avoids a genuine
/// hazard in a concurrency test: `TPPUserAccount` serializes its credential
/// state through a synchronous `accountInfoQueue.sync(flags: .barrier)`, so N
/// concurrent activations against a real account occupy N cooperative-pool
/// threads in blocking dispatch work. Whether that alone is enough to starve
/// the pool was not measured — the point is that a test of concurrency should
/// not be doing blocking I/O in the first place.
protocol AdobeActivationAccount: AnyObject, Sendable {
    var userID: String? { get }
    var deviceID: String? { get }
    var licensor: [String: Any]? { get }
    func setUserID(_ id: String)
    func setDeviceID(_ id: String)
}

extension TPPUserAccount: AdobeActivationAccount {}

/// Serializes Adobe device activation so at most one activation is ever in
/// flight, no matter how many callers ask for one.
///
/// Modeled on `TokenRefreshCoordinator` in `TPPNetworkExecutor`.
///
/// This type does single-flight and NOTHING ELSE. Bounding the underlying work
/// is deliberately the caller's job, because only the caller knows how to
/// interrupt its own operation.
///
/// An earlier revision tried to bound the work here by wrapping it in
/// `BorrowOperation.withTimeout`. That is INERT against the shape that actually
/// matters. `withTimeout` is a `withThrowingTaskGroup`, and a task group awaits
/// every child on scope exit while `cancelAll()` is only cooperative. The real
/// operation is a `withCheckedThrowingContinuation` around `adept.authorize`,
/// which RMSDK may simply never resume and which cancellation cannot resume. The
/// group would therefore never unwind, `inFlight` would never clear, and every
/// later borrow would coalesce onto a dead task — strictly worse than having no
/// gate at all, where a wedge costs exactly one borrow. The guard's test passed
/// only because it stood in a cancellable `Task.sleep` for the hang.
///
/// The deadline now lives on the continuation itself (see
/// `AdobeDRMService.ensureDeviceActivated`), where a one-shot latch can resume it
/// and the awaiting task genuinely unwinds.
actor AdobeActivationCoordinator {

    /// Ceiling a caller should apply to a single activation. Adobe activation is
    /// a network round trip plus local key generation; 90s is generous for a slow
    /// connection while still bounding a wedge to something a patron can retry
    /// past rather than a permanently dead borrow button.
    static let defaultTimeout: TimeInterval = 90

    /// The activation currently in flight, if any. Non-nil only between the
    /// moment a caller claims the slot and the moment that caller's `activate`
    /// returns.
    private var inFlight: Task<Void, Error>?

    /// Number of times the slot was actually claimed — i.e. how many times the
    /// underlying RMSDK `authorize` really ran. Callers that coalesce behind an
    /// in-flight activation do NOT increment this. This is the number the
    /// de-duplication tests assert on.
    private(set) var activationAttemptCount = 0

    /// How many callers coalesced onto an already-in-flight activation, i.e.
    /// how many concurrent borrows this gate kept OUT of Adobe's RMSDK. Plain
    /// observable state — tests poll it rather than waiting on a continuation
    /// barrier, which is deliberately boring: the barrier this replaced had a
    /// lost-wake-up that parked the suite instead of failing it.
    private(set) var coalescedCount = 0

    /// Runs `work` unless an activation is already in flight, in which case the
    /// caller awaits the in-flight result instead of starting a second one.
    ///
    /// Failure is shared: if the in-flight activation fails, every coalesced
    /// caller sees that same error. This is intentional — the alternative
    /// (each waiter retrying on its own) reintroduces exactly the concurrent
    /// RMSDK entry this type exists to prevent. Callers retry at the borrow
    /// level, by which point the slot is free.
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
        // cannot re-enter it. `work` is `@Sendable`; RMSDK's completion block is
        // already `@Sendable` per `TPPDRMAuthorizing`, so this does not repeat
        // the non-Sendable-completion trap that bit `boundedCompletion`.
        let task = Task.detached(priority: .userInitiated) { try await work() }

        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

}
