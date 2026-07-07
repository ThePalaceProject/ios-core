//
//  AdobeCertificate.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.08.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation
import PalaceLogging

/// Adobe DRM Certificate structure.
///
/// Includes only fields Palace checks to verify the certificate is not expired.
///
/// Swift 6 `complete`: `final` + `Sendable`. The only stored property is the
/// immutable `let expireson: UInt?` (Sendable), so the value is deeply immutable
/// and safe to share across concurrency domains — which is what lets the cached
/// `static let defaultCertificate` be concurrency-safe. No subclasses exist.
@objc final class AdobeCertificate: NSObject, Codable, Sendable {

    /// Certificate expiration date, seconds since UNIX epoch.
    ///
    /// This field is not present in production certificates.
    let expireson: UInt?

    /// Initializes certificate data
    init(expireson: UInt?) {
        self.expireson = expireson
    }
}

extension AdobeCertificate {

    /// Certificate expiration date.
    @objc var expirationDate: Date? {
        guard let expireson = expireson else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(expireson))
    }

    /// Returns `true` if certificate has already expired.
    ///
    /// If expiration date is not present in certificate data, returns `false`
    @objc var hasExpired: Bool {
        guard let expirationDate = expirationDate else {
            return false
        }
        return expirationDate.timeIntervalSinceNow <= 0
    }

    /// Safely checks if DRM is available and certificate is valid.
    /// Use this before attempting any DRM operations.
    @objc static var isDRMAvailable: Bool {
        // Adobe RMSDK is not validated for the "iPad apps on Mac" runtime — its
        // static C++ destructors race with macOS process exit and abort with
        // recursive_mutex EINVAL during background suspension. Treating DRM as
        // unavailable on iOS_ON_MAC keeps RMSDK from initializing at all, which
        // eliminates the static state that crashes at teardown.
        // (Crashlytics 9a91840677 — 89 users, 294 events, all iOS_ON_MAC.)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return false
        }
        guard let cert = defaultCertificate else {
            return false
        }
        return !cert.hasExpired
    }

    /// Default certificate for Palace app.
    ///
    /// Swift 6 `complete`: `static let` (was `var`, never reassigned). Now that
    /// `AdobeCertificate` is `Sendable`, this cached immutable value is
    /// concurrency-safe to read from any thread.
    @objc static let defaultCertificate: AdobeCertificate? = {
        let bundle: Bundle = (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) ? Bundle(for: TPPAppDelegate.self) : Bundle.main
        guard let adobeCertUrl = bundle.url(forResource: "ReaderClientCert", withExtension: "sig"),
              let adobeCertData = try? Data(contentsOf: adobeCertUrl),
              !adobeCertData.isEmpty else {
            return nil
        }
        return AdobeCertificate(data: adobeCertData)
    }()

    /// Initialise with Adobe DRM certificate data.
    /// - Parameter data: `ReaderClientCert.sig` data.
    @objc convenience init?(data: Data) {
        if let cert = try? JSONDecoder().decode(AdobeCertificate.self, from: data) {
            self.init(expireson: cert.expireson)
        } else {
            return nil
        }
    }

    /// Period of notification for expired Adobe DRM certificate
    fileprivate static let notificationPeriod: TimeInterval = 60 * 60

    /// Last expired DRM certificate notification date.
    ///
    /// Swift 6 `complete`: backed by a lock-backed `@unchecked Sendable` holder
    /// instead of a bare mutable `static var` (which is not concurrency-safe).
    /// `shouldNotifyAboutExpiration` may be evaluated from any thread that hits an
    /// expired-cert branch, so the read-decide-write must be serialized.
    fileprivate static let notificationDateHolder = DateHolder()

    /// Returns true every `notificationPeriod` time interval.
    ///
    /// Used to avoid showing expiration message every time the user opens the app with expired certificate.
    @objc static var shouldNotifyAboutExpiration: Bool {
        // Perform the read-decide-write atomically under the holder's lock so two
        // concurrent expired-cert checks can't both return `true` for the same window.
        notificationDateHolder.notifyIfElapsed(period: notificationPeriod)
    }

}

/// Lock-backed holder for the expired-certificate notification timestamp.
///
/// Swift 6 `complete`: replaces the bare mutable `static var notificationDate`.
/// `@unchecked Sendable` is honest here because the single mutable field is only
/// ever touched inside `notifyIfElapsed`, which holds `lock` for the whole
/// read-decide-write — so no unsynchronized access is possible. Precedent:
/// `AdobeDRMService`'s lock-backed statics in this same file.
private final class DateHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    /// Atomically returns `true` at most once per `period`, recording "now" on the
    /// firing call. Mirrors the original `shouldNotifyAboutExpiration` semantics.
    func notifyIfElapsed(period: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let date, -date.timeIntervalSinceNow < period {
            return false
        }
        date = Date()
        return true
    }
}

/// Lock-backed holder for the iPad-on-Mac static-destructor-bypass flags.
///
/// Swift 6 `complete`: replaces the two bare mutable `static var`s
/// (`staticDestructorBypassRegistered`, `adobeDRMUsed`) and their `NSLock`.
/// `@unchecked Sendable` is honest because both fields are only ever read or
/// written inside a method that holds `lock` for the whole operation — there is no
/// unsynchronized access. The `markRegisteredIfNeeded` closure runs while the lock
/// is held, so the caller's decision sees a consistent `registered` snapshot and
/// the flip is atomic with it.
private final class BypassState: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var used = false

    var adobeDRMUsed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return used
    }

    func setAdobeDRMUsed(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        used = value
    }

    /// Atomically evaluates `decide(currentRegisteredFlag)` and, if it returns
    /// `true`, flips `registered` to `true` and returns `true` (meaning "you should
    /// install now"). Returns `false` otherwise. One-shot install guard.
    func markRegisteredIfNeeded(_ decide: (Bool) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard decide(registered) else { return false }
        registered = true
        return true
    }
}

// MARK: - Safe DRM Access

/// Provides thread-safe access to Adobe DRM functionality.
/// Wraps NYPLADEPT.sharedInstance() with defensive error handling to prevent crashes.
/// Note: Named AdobeDRMService to avoid conflict with Obj-C AdobeDRMContainer (the decryption container)
///
/// Swift 6 `complete`: `@unchecked Sendable`. INVARIANT — all instance mutable
/// state (`_adeptInstance`, `initializationAttempted`, `initializationFailed`) is
/// accessed only under `lock`, and all mutable static state is owned by the
/// `bypassState` lock-backed holder below. No unsynchronized shared mutation
/// remains, which is what makes the `static let shared` singleton
/// concurrency-safe.
@objcMembers
class AdobeDRMService: NSObject, @unchecked Sendable {

    /// Singleton for safe DRM access
    static let shared = AdobeDRMService()

    /// Lock for thread-safe singleton access
    private let lock = NSLock()

    /// Cached reference to NYPLADEPT instance
    private var _adeptInstance: NYPLADEPT?

    /// Flag to track if initialization has been attempted
    private var initializationAttempted = false

    /// Flag to track if initialization failed
    private var initializationFailed = false

    private override init() {
        super.init()
    }

    /// Prepare for app termination by clearing cached references.
    /// This helps prevent "recursive_mutex lock failed" crashes on Mac Catalyst
    /// when the FinalTerminationWatchdog forces app exit and triggers C++ static
    /// destructors while Adobe DRM objects are in an inconsistent state.
    func prepareForTermination() {
        lock.lock()
        defer { lock.unlock() }

        // Clear delegate to prevent callbacks during shutdown
        _adeptInstance?.delegate = nil

        // Clear our cached reference (doesn't destroy the underlying C++ objects,
        // but helps avoid our code interacting with them during shutdown)
        _adeptInstance = nil

        Log.info(#file, "Adobe DRM prepared for termination")
    }

    // MARK: - iPad-on-Mac static-destructor bypass

    /// Swift 6 `complete`: the two process-exit-bypass flags plus their lock are
    /// consolidated into one lock-backed `@unchecked Sendable` holder instead of
    /// bare mutable `static var`s (which are not concurrency-safe). The holder is
    /// the single serialization domain for `registered` + `adobeDRMUsed`; every
    /// read-decide-write below runs inside it, so the semantics are unchanged.
    private static let bypassState = BypassState()

    /// Records that Adobe DRM is being exercised this session. Called when an
    /// `AdobeDRMContainer` is constructed (the broad reader-DRM umbrella).
    static func markAdobeDRMUsed() {
        bypassState.setAdobeDRMUsed(true)
    }

    /// Whether Adobe DRM has been exercised this session. The
    /// `applicationDidEnterBackground` install site consults this so the
    /// `_exit(0)` interceptor is only installed once an Adobe dtor exists.
    static var didUseAdobeDRMThisSession: Bool {
        bypassState.adobeDRMUsed
    }

    /// Test-only: reset the session "DRM used" flag so the false→true contract
    /// can be asserted hermetically (the flag is otherwise set-once per process).
    /// Internal — not part of any production call path.
    static func resetAdobeDRMUsedForTesting() {
        bypassState.setAdobeDRMUsed(false)
    }

    /// Pure decision: should *this* call install the atexit interceptor now?
    /// True only on iOS-app-on-Mac AND only if not already installed
    /// (idempotent). Split out from the side-effecting registration so the
    /// gating + one-shot "registration timing" is unit-testable without
    /// invoking the real `atexit`/`_exit`.
    static func shouldRegisterStaticDestructorBypass(isiOSAppOnMac: Bool,
                                                     alreadyRegistered: Bool) -> Bool {
        shouldSkipStaticDestructorsOnExit(isiOSAppOnMac: isiOSAppOnMac) && !alreadyRegistered
    }

    /// Installs a LIFO-first `atexit` interceptor that hard-exits via `_exit(0)`
    /// on iOS-app-on-Mac, covering the forced/watchdog `exit()` path that skips
    /// `applicationWillTerminate`.
    ///
    /// CALL SITE MATTERS — call this from `applicationDidEnterBackground` once
    /// `didUseAdobeDRMThisSession` is true. Ordering rationale, robust to the
    /// (unmeasured) construction timing of Adobe's faulting static
    /// `recursive_mutex`: `atexit` and `__cxa_atexit` share one LIFO list, so to
    /// pop `_exit(0)` BEFORE Adobe's destructor we must register ours AFTER
    /// Adobe's `__cxa_atexit(dtor)`. By the time the app enters the background,
    /// every Adobe-DRM `decode()` of this session has already run, so the mutex
    /// is constructed and its dtor registered whenever it was going to be —
    /// dylib-load (before `main`) OR lazily on some DRM op. Installing at
    /// background entry is therefore LIFO-after Adobe's dtor in BOTH cases. It is
    /// also temporally adjacent to the background-suspension watchdog `exit()`
    /// where the 294 crashes fire. (A launch-time or first-`decode()` install
    /// risks latching too early — before the mutex's construction — which the
    /// at-most-once guard would lock in.) The `isDRMAvailable` iOS-on-Mac gate
    /// only covers `AdobeDRMService` fulfillment/activation — NOT the reader
    /// decrypt path — which is why the crash fires on iOS-on-Mac despite it.
    ///
    /// Idempotent; no-op on iOS devices. End-to-end behavior (crash-at-exit) is
    /// not unit-testable — requires simdrive validation on a Mac host (CHECK 2).
    static func registerStaticDestructorBypassIfNeeded() {
        // Atomic check-and-set inside the holder's lock: the pure decision
        // (`shouldRegisterStaticDestructorBypass`) runs against the currently-stored
        // `registered` flag, and the flag is only flipped to `true` when the guard
        // passes — so the `atexit` interceptor installs at most once even under
        // concurrent callers.
        let shouldInstall = bypassState.markRegisteredIfNeeded { alreadyRegistered in
            shouldRegisterStaticDestructorBypass(
                isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
                alreadyRegistered: alreadyRegistered
            )
        }
        guard shouldInstall else { return }
        _ = atexit { _exit(0) }
    }

    /// Safely get the NYPLADEPT shared instance.
    /// Returns nil if DRM is not available or initialization fails.
    var adeptInstance: NYPLADEPT? {
        lock.lock()
        defer { lock.unlock() }

        // Return cached instance if available
        if let instance = _adeptInstance {
            return instance
        }

        // Don't retry if initialization already failed
        if initializationFailed {
            return nil
        }

        // Check DRM availability before attempting access
        guard AdobeCertificate.isDRMAvailable else {
            Log.info(#file, "Adobe DRM not available - certificate missing or expired")
            initializationFailed = true
            return nil
        }

        // Attempt to get the shared instance safely
        initializationAttempted = true

        // Access the shared instance - this can crash with EXC_BREAKPOINT
        // if the Adobe DRM library fails to initialize properly
        _adeptInstance = NYPLADEPT.sharedInstance()

        if _adeptInstance == nil {
            Log.error(#file, "Failed to initialize Adobe DRM - NYPLADEPT.sharedInstance() returned nil")
            initializationFailed = true
        }

        return _adeptInstance
    }

    /// Safely check if a user is authorized for DRM content.
    /// Returns false if DRM is not available.
    func isUserAuthorized(_ userID: String?, deviceID: String?) -> Bool {
        guard let adept = adeptInstance,
              let userID = userID,
              let deviceID = deviceID else {
            return false
        }
        return adept.isUserAuthorized(userID, withDevice: deviceID)
    }

    /// Safely set the delegate for DRM callbacks.
    func setDelegate(_ delegate: NYPLADEPTDelegate?) {
        guard let adept = adeptInstance else {
            Log.warn(#file, "Cannot set DRM delegate - Adobe DRM not available")
            return
        }
        adept.delegate = delegate
    }

    /// Check if DRM is ready for use
    var isReady: Bool {
        return adeptInstance != nil
    }

    /// Safely cancel a DRM fulfillment operation.
    func cancelFulfillment(withTag tag: String) {
        guard let adept = adeptInstance else {
            Log.warn(#file, "Cannot cancel DRM fulfillment - Adobe DRM not available")
            return
        }
        adept.cancelFulfillment(withTag: tag)
    }

    /// Safely return a DRM loan.
    // Swift 6 `complete`: `completion` is `@Sendable` because it is forwarded to
    // `NYPLADEPT.returnLoan`, whose imported Obj-C block parameter is `@Sendable`
    // (the DRM callback fires on a background RMSDK thread). The sole caller
    // (`BookReturnService`) passes a closure that captures nothing non-Sendable, so
    // this does not ripple.
    func returnLoan(_ fulfillmentId: String?,
                    userID: String?,
                    deviceID: String?,
                    completion: @escaping @Sendable (Bool, Error?) -> Void) {
        guard let adept = adeptInstance else {
            Log.warn(#file, "Cannot return DRM loan - Adobe DRM not available")
            completion(false, NSError(domain: "AdobeDRM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Adobe DRM not available"]))
            return
        }
        adept.returnLoan(fulfillmentId, userID: userID, deviceID: deviceID, completion: completion)
    }

    /// Safely fulfill a DRM-protected download.
    func fulfill(withACSMData acsmData: Data,
                 tag: String,
                 userID: String?,
                 deviceID: String?) {
        guard let adept = adeptInstance else {
            Log.error(#file, "Cannot fulfill DRM content - Adobe DRM not available")
            return
        }
        adept.fulfill(withACSMData: acsmData, tag: tag, userID: userID, deviceID: deviceID)
    }

    // MARK: - On-Demand Activation

    /// Ensures the device is activated with Adobe DRM, performing on-demand
    /// activation if needed. This is called at borrow time for Adobe DRM content
    /// instead of at login, to avoid burning activations unnecessarily.
    ///
    /// - Throws: `PalaceError.drm` if activation fails or credentials are unavailable.
    func ensureDeviceActivated() async throws {
        let userAccount = AppContainer.production().accountsManager.currentUserAccount

        if let userID = userAccount.userID,
           let deviceID = userAccount.deviceID,
           isUserAuthorized(userID, deviceID: deviceID) {
            Log.info(#file, "Adobe device already activated — skipping activation")
            return
        }

        guard AdobeCertificate.isDRMAvailable else {
            Log.error(#file, "Adobe DRM not available — certificate missing or expired")
            throw PalaceError.drm(.noActivation)
        }

        guard let licensor = userAccount.licensor,
              let vendor = licensor["vendor"] as? String, !vendor.isEmpty,
              let clientToken = licensor["clientToken"] as? String, !clientToken.isEmpty else {
            Log.error(#file, "No Adobe DRM licensor credentials stored — cannot activate")
            throw PalaceError.drm(.noActivation)
        }

        var items = clientToken
            .replacingOccurrences(of: "\n", with: "")
            .components(separatedBy: "|")
        let tokenPassword = items.last
        items.removeLast()
        let tokenUsername = (items as NSArray).componentsJoined(by: "|")

        Log.info(#file, "Performing on-demand Adobe device activation for borrow")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let adept = self.adeptInstance else {
                continuation.resume(throwing: PalaceError.drm(.noActivation))
                return
            }

            adept.authorize(withVendorID: vendor,
                            username: tokenUsername,
                            password: tokenPassword) { success, error, deviceID, userID in
                if success, let userID = userID, let deviceID = deviceID {
                    Log.info(#file, "On-demand Adobe activation succeeded")
                    TPPMainThreadRun.asyncIfNeeded {
                        userAccount.setUserID(userID)
                        userAccount.setDeviceID(deviceID)
                    }
                    continuation.resume()
                } else {
                    let activationError = error ?? NSError(
                        domain: "AdobeDRM",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Adobe device activation failed"]
                    )
                    Log.error(#file, "On-demand Adobe activation failed: \(activationError.localizedDescription)")
                    TPPErrorLogger.logError(
                        withCode: .invalidLicensor,
                        summary: "On-demand Adobe device activation failed (PP-3649)",
                        metadata: ["error": activationError.localizedDescription]
                    )
                    continuation.resume(throwing: PalaceError.drm(.authenticationFailed))
                }
            }
        }
    }
}

#endif
