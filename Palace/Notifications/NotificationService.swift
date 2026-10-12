//
//  NotificationService.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

@preconcurrency import UserNotifications
import Combine
import FirebaseCore
import PalaceBookRegistry
// `@preconcurrency`: Firebase Messaging's handlers carry `@Sendable`/isolation
// expectations this class cannot meet without class-level `@MainActor`, which it
// avoids because it is called off-main (e.g. from book-registry sync).
@preconcurrency import FirebaseMessaging
import PalaceLogging
import PalaceBookModel

// MARK: - Notification Constants

/// Category identifier for local hold availability notifications
let HoldNotificationCategoryIdentifier = "NYPLHoldToReserveNotificationCategory"
/// Action identifier for checkout action on local notifications
let CheckOutActionIdentifier = "NYPLCheckOutNotificationAction"
/// Default action identifier for notification taps
let DefaultActionIdentifier = "UNNotificationDefaultActionIdentifier"

// MARK: - NotificationService

/// Consolidated notification service for the Palace app.
///
/// Handles:
/// - Push notifications from Firebase Cloud Messaging (FCM)
/// - Local notifications for hold availability (reserved → ready transitions)
/// - App icon badge updates for ready holds
/// - FCM token management with the library server
///
/// This service is the sole `UNUserNotificationCenterDelegate` for the app.
@objcMembers
class NotificationService: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate, @unchecked Sendable {

    /// Token data structure
    ///
    /// Based on API documentation
    /// https://www.notion.so/lyrasis/Send-push-notifications-for-reservation-availability-and-loan-expiry-2866943ebe774cbd90b5df81db811648
    struct TokenData: Codable {
        let device_token: String
        let token_type: String

        init(token: String) {
            self.device_token = token
            self.token_type = "FCMiOS"
        }

        var data: Data? {
            try? JSONEncoder().encode(self)
        }
    }

    // MARK: - Registration claims

    /// Tracks which accounts have a registration attempt in flight.
    ///
    /// Extracted as its own type so the claim/release contract is testable without
    /// an `Account`, an `AccountsManager`, or a simulator. It was a single global
    /// `Bool` first, which meant a library switch during the readiness wait had the
    /// incoming account's trigger rejected by the outgoing account's attempt — the
    /// incoming library then went unregistered until relaunch, nondeterministically.
    /// Keying by uuid is what fixes that, so the keying itself is worth pinning.
    final class RegistrationClaims: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight: Set<String> = []

        /// Returns true if THIS caller now owns the slot for `uuid`.
        func claim(_ uuid: String) -> Bool {
            lock.withLock {
                if inFlight.contains(uuid) { return false }
                inFlight.insert(uuid)
                return true
            }
        }

        func release(_ uuid: String) {
            lock.withLock { _ = inFlight.remove(uuid) }
        }

        /// Whether an attempt is currently in flight for `uuid`.
        ///
        /// `fileprivate`, not `private`: the enclosing type's
        /// `isRegistrationClaimed(_:)` forwarder calls it, and an outer type
        /// cannot reach a nested type's private members.
        fileprivate func isClaimed(_ uuid: String) -> Bool {
            lock.withLock { inFlight.contains(uuid) }
        }
    }

    // `@unchecked Sendable`: `self` is captured into Firebase Messaging `@Sendable`
    // completions, `@MainActor` Tasks, and `.main` NotificationCenter observers.
    // Dependencies are `let`s (`accountsManager` is constrained `& Sendable`); the
    // two mutable `var`s are guarded by `authStateLock`. Class-level `@MainActor` is
    // not used because Firebase callbacks run off-main.

    private let notificationCenter = UNUserNotificationCenter.current()
    /// Typed to the protocol so tests can substitute it. Tests observe the
    /// readiness gate through claim lifetime (`RegistrationClaims.isClaimed`), not
    /// by counting reads of this property, which is also read from other paths;
    /// see `NotificationServiceReadinessGateTests`.
    private let accountsManager: any TPPLibraryAccountsProvider & Sendable
    private let networkExecutor: TPPNetworkExecutor
    private let bookRegistry: TPPBookRegistryProvider

    /// Guards `authStateSubscription` and `lastObservedAuthState`.
    private let authStateLock = NSLock()
    /// Subscription to the auth-state-change publisher. Set in
    /// `subscribeToAuthStateChanges(_:retry:)`. Held to keep the
    /// subscription alive for the lifetime of the service. Guarded by `authStateLock`.
    private var authStateSubscription: AnyCancellable?
    /// Last observed auth state — used to decide whether the next
    /// emission is a recovery transition (i.e. landed on `.loggedIn`
    /// from a non-`.loggedIn` state). Nil before any emission. Guarded by `authStateLock`.
    private var lastObservedAuthState: TPPAccountAuthState?
    /// True when this instance was created with the test-only
    /// `init(authStatePublisher:onAuthStateRetryRequested:)` so the
    /// asynchronous production subscription hop is skipped.
    private let skipsProductionAuthSubscription: Bool

    static let shared = NotificationService()

    override init() {
        self.accountsManager = AppContainer.production().accountsManager
        self.networkExecutor = AppContainer.production().networkExecutor
        self.bookRegistry = AppContainer.production().bookRegistry
        self.skipsProductionAuthSubscription = false
        super.init()

        installNotificationObservers()

        // Re-attempt FCM token registration when stale credentials recover to
        // `.loggedIn`. Otherwise a patron who passed through `.credentialsStale`
        // would not re-register until cold launch, sign-out, or library switch,
        // and would get no hold-availability pushes. The MainActor hop is needed
        // because `UserAccountPublisher.shared` is `@MainActor`-isolated.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.skipsProductionAuthSubscription else { return }
            self.subscribeToAuthStateChanges(
                UserAccountPublisher.shared.authStateDidChangePublisher,
                retry: { [weak self] in self?.updateToken() }
            )
        }
    }

    /// Test-only initializer that injects the auth-state publisher and
    /// retry callback. Production code uses the no-arg `init()` which
    /// wires `UserAccountPublisher.shared.authStateDidChangePublisher`
    /// and `updateToken()`; tests inject a `PassthroughSubject` and a
    /// spy closure to verify the retry decision logic without standing
    /// up Firebase Messaging.
    ///
    /// `@nonobjc` because `AnyPublisher` is not Objective-C bridgeable
    /// (the enclosing class is `@objcMembers`).
    @nonobjc
    init(
        authStatePublisher: AnyPublisher<TPPAccountAuthState, Never>,
        onAuthStateRetryRequested: @escaping () -> Void,
        accountsManager: (any TPPLibraryAccountsProvider & Sendable)? = nil
    ) {
        // Resolved here rather than as a default argument: default arguments
        // are evaluated at the call site, which can re-enter AppContainer's
        // lock and abort launch.
        self.accountsManager = accountsManager ?? AppContainer.production().accountsManager
        self.networkExecutor = AppContainer.production().networkExecutor
        self.bookRegistry = AppContainer.production().bookRegistry
        self.skipsProductionAuthSubscription = true
        super.init()

        installNotificationObservers()
        subscribeToAuthStateChanges(authStatePublisher, retry: onAuthStateRetryRequested)
    }

    /// Shared NSNotificationCenter observer wiring used by both the
    /// no-arg production init and the test-only init.
    ///
    /// `NotificationService.shared` is an app-lifetime singleton; the
    /// observers below are intentionally never deregistered because the
    /// service outlives every other component in the app graph. Re-init
    /// is not a concern (the production seam is the `static let shared`
    /// — Swift guarantees one-shot initialization), so the PP-4329
    /// double-fire / re-init leak class doesn't apply here. The
    /// `// no-observer-storage:` annotations below opt out of the D5-1
    /// detector explicitly.
    private func installNotificationObservers() {
        // no-observer-storage: NotificationService.shared is an app-lifetime
        // singleton; this observer is meant to live until process exit.
        // Update library token when the user changes library account.
        NotificationCenter.default.addObserver(forName: NSNotification.Name.TPPCurrentAccountDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateToken()
        }
        // no-observer-storage: NotificationService.shared is an app-lifetime
        // singleton; this observer is meant to live until process exit.
        // Update library token when the user signs in (but has already added the library)
        NotificationCenter.default.addObserver(forName: NSNotification.Name.TPPIsSigningIn, object: nil, queue: .main) { [weak self] notification in
            if let isSigningIn = notification.object as? Bool, !isSigningIn {
                self?.updateToken()
            }
        }
    }

    /// Wires the auth-state-change subscription. Each emission consults
    /// the pure `shouldRetryTokenRegistration` helper against the
    /// previously-observed state; on a recovery transition the `retry`
    /// closure is invoked.
    private func subscribeToAuthStateChanges(
        _ publisher: AnyPublisher<TPPAccountAuthState, Never>,
        retry: @escaping () -> Void
    ) {
        let subscription = publisher.sink { [weak self] newState in
            guard let self else { return }
            let previous = self.authStateLock.withLock { () -> TPPAccountAuthState? in
                let prior = self.lastObservedAuthState
                self.lastObservedAuthState = newState
                return prior
            }
            // Without a prior state we have no transition to evaluate —
            // just record the first emission as the new baseline.
            guard let previous else { return }
            let flag = self.accountsManager.currentAccount?.hasUpdatedToken ?? false
            guard Self.shouldRetryTokenRegistration(
                previous: previous,
                current: newState,
                hasUpdatedToken: flag
            ) else { return }
            Log.info(#file, "[FCM_REG] auth-state recovery detected: \(previous)→\(newState), hasUpdatedToken=\(flag) — re-attempting token registration")
            retry()
        }
        authStateLock.withLock { authStateSubscription = subscription }
    }

    /// Cancels the auth-state subscription. Used by tests to deflake
    /// teardown; production code holds the subscription for the full
    /// app lifetime.
    func cancelAuthStateSubscription() {
        authStateLock.withLock {
            authStateSubscription?.cancel()
            authStateSubscription = nil
            lastObservedAuthState = nil
        }
    }

    /// Pure decision helper for the auth-state-change retry path.
    /// Returns true iff the transition is a recovery edge — i.e. the
    /// new state is `.loggedIn`, the previous state was something else,
    /// and `hasUpdatedToken == false` (meaning the prior registration
    /// attempt did not confirm with the Circulation Manager). Mutation
    /// testing pins every branch via the `NotificationServiceTokenTests`
    /// `testShouldRetryTokenRegistration_*` cases.
    static func shouldRetryTokenRegistration(
        previous: TPPAccountAuthState,
        current: TPPAccountAuthState,
        hasUpdatedToken: Bool
    ) -> Bool {
        guard current == .loggedIn else { return false }
        guard previous != .loggedIn else { return false }
        return !hasUpdatedToken
    }

    /// Whether a nil profile document is worth reporting as a failure.
    ///
    /// A signed-out patron has nothing to register, so deferring is the correct
    /// outcome rather than a fault. The observed traffic includes that case — a
    /// Settings library switch to a library the patron is not signed in to —
    /// and reporting it buried the genuine failures. Kept as a pure predicate
    /// so the decision is table-testable, mirroring
    /// `shouldRetryTokenRegistration`.
    static func shouldReportProfileFetchFailure(authState: TPPAccountAuthState) -> Bool {
        authState != .loggedOut
    }

    /// What to do when the readiness wait throws.
    ///
    /// Extracted as a pure decision because this arm has been wrong TWICE: first
    /// it reported nothing (burying genuine failures), then it reported
    /// `.evicted` as a hard failure (filing false ones on every library switch,
    /// against the very metric this fix is measured by). A five-case table is
    /// enumerable; a branch buried in a Task is not.
    enum ReadinessFailureDisposition: Equatable {
        /// Expected and high-volume. Stay silent — a later auth-doc drive
        /// resolves it and the next trigger registers.
        case quiet
        /// Expected before this fix, and the RESIDUAL defect population after
        /// it. Report under its own summary.
        ///
        /// This case exists so the fix stays falsifiable. Making the timeout
        /// silent would drive `d63871fd…` to near-zero whether registration
        /// now succeeds or the account is simply never driven — the metric
        /// would confirm the fix by construction. At t=0 "not ready yet" was
        /// noise; after a 45s bounded wait it means a genuinely wedged
        /// authentication document, which is a small, real, and different
        /// population that we need to be able to see.
        case residual
        /// The authentication document will not arrive. Report it.
        case report
    }

    static func disposition(forReadinessFailure error: AccountLoadError) -> ReadinessFailureDisposition {
        switch error {
        case .readinessTimedOut:
            // Waited the full bound and the document still had not arrived.
            // Low volume by construction, and the population this fix does NOT
            // help — kept visible so success is measurable rather than assumed.
            return .residual
        case .evicted:
            // Library switch. AuthDocumentLoader re-drives this, and the
            // incoming account registers on its own trigger.
            return .quiet
        case .authDocumentFetchFailed, .malformedAuthDocument, .accountNotFound:
            // The document genuinely will not arrive for this account.
            return .report
        }
    }

    static func sharedService() -> NotificationService {
        return shared
    }

    /// Runs configuration function, registers the app for remote notifications.
    func setupPushNotifications(completion: (@Sendable (_ granted: Bool) -> Void)? = nil) {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            completion?(granted)
        }
        Messaging.messaging().delegate = self
    }

    func getNotificationStatus(completion: @escaping @Sendable (_ areEnabled: Bool) -> Void) {
        notificationCenter.getNotificationSettings { notificationSettings in
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional: completion(true)
            default: completion(false)
            }
        }
    }

    /// Check if token exists on the server
    /// - Parameters:
    ///   - token: FCM token value
    ///   - completion: `(exists: Bool, error: Error?) -> Void`
    ///
    /// The existence of the token is based on the server response status code:
    /// - 200: exists
    /// - 404 doesn't exist
    /// `exists` is `nil` for any other response status code.
    private func checkTokenExists(_ token: String, endpointUrl: URL, completion: @escaping (Bool?, Error?) -> Void) {
        guard
            let requestUrl = URL(string: "\(endpointUrl.absoluteString)?device_token=\(token)")
        else {
            return
        }
        let request = URLRequest(url: requestUrl, applyingCustomUserAgent: true)
        _ = networkExecutor.addBearerAndExecute(request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            // Token exists if status code is 200, doesn't exist if 404.
            switch status {
            case 200: completion(true, error)
            case 404: completion(false, error)
            default: completion(nil, error)
            }
        }
    }

    /// Save token to the server
    /// - Parameters:
    ///   - token: FCM token value
    ///   - endpointUrl: device-registration endpoint
    ///   - completion: invoked with `true` only when the PUT returned a 2xx
    ///     status. Used by `updateToken` to gate `hasUpdatedToken`.
    private func saveToken(_ token: String, endpointUrl: URL, completion: ((Bool) -> Void)? = nil) {
        guard let requestBody = TokenData(token: token).data else {
            completion?(false)
            return
        }
        var request = URLRequest(url: endpointUrl, applyingCustomUserAgent: true)
        request.httpMethod = "PUT"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = networkExecutor.addBearerAndExecute(request) { _, response, error in
            if let error = error {
                TPPErrorLogger.logError(error,
                                        summary: "Couldn't upload token data",
                                        metadata: [
                                            "requestURL": endpointUrl,
                                            "tokenData": String(data: requestBody, encoding: .utf8) ?? "",
                                            "statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0
                                        ]
                )
                completion?(false)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion?((200..<300).contains(status))
        }
    }

    /// How long to wait for the current account's authentication document
    /// before giving up on this registration attempt.
    ///
    /// Bounded because an unbounded `awaitReady()` on a background path is the
    /// HelpSpot #18414 load-forever hang.
    ///
    /// 45s: the auth document can take over 10s on a cold network
    /// (`docs/architecture/account-state-machine.md`), and the wait must exceed
    /// `authDocInflightTimeout` (30s) to benefit from its wedge reclaim. Nothing
    /// re-fires registration after a timeout, so this budget is final.
    static let accountReadinessTimeout: TimeInterval = 45

    /// Coalesces the READINESS WAIT per account. Released when the Task body
    /// returns — i.e. when registration STARTS its network chain, not when the
    /// `/patrons/me/` fetch and PUT finish. So it prevents N concurrent waits
    /// collapsing into N registrations; it does not serialise two triggers that
    /// both arrive on an already-ready account.
    private let registrationClaims = RegistrationClaims()

    /// Read-only view of the claim table, for the readiness-gate test.
    ///
    /// The table itself is `private`: a stray `claim(_:)` would block push
    /// registration for that account permanently, since only the owning
    /// attempt's `defer` releases it.
    func isRegistrationClaimed(_ uuid: String) -> Bool {
        registrationClaims.isClaimed(uuid)
    }

    /// Sends FCM to the backend
    ///
    /// Update token when user account changes.
    ///
    /// `hasUpdatedToken` is set only once the server confirms the token
    /// (already exists or save succeeded). Setting it earlier would block every
    /// retry after a failed profile fetch, e.g. with stale SAML credentials, and
    /// the patron would get no hold notifications (HelpSpot 17680).
    func updateToken() {
        guard !(accountsManager.currentAccount?.hasUpdatedToken ?? false) else {
            return
        }

        // [FCM_REG] prefixes every outcome log so support logs show which step
        // blocked registration; the CM has no server-side signal for it.
        let authState = accountsManager.currentUserAccount.authState
        Log.info(#file, "[FCM_REG] updateToken start — authState=\(authState)")

        guard let account = accountsManager.currentAccount else {
            Log.warn(#file, "[FCM_REG] SKIP: no current account")
            return
        }

        // PP-4958: wait for the auth document before `getProfileDocument`, which
        // returns nil without one. The FCM callback fires at launch before the
        // document lands, and a library switch notifies before the new account's
        // document is fetched; nothing else would retry registration.
        //
        // `awaitReady` fast-paths when the account is already terminal, so a
        // ready account pays nothing for this.
        // Claim this ACCOUNT's slot before waiting. Released on every exit path.
        let uuid = account.uuid
        guard registrationClaims.claim(uuid) else {
            Log.info(#file, "[FCM_REG] SKIP: a registration attempt is already in flight for this account")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer { self.registrationClaims.release(uuid) }
            do {
                _ = try await account.awaitReady(timeout: Self.accountReadinessTimeout)
            } catch let error as AccountLoadError {
                // Three dispositions:
                //   .readinessTimedOut — .residual: the 45s bound elapsed. Reported
                //     under its own summary so a never-driven account stays visible.
                //   .evicted — .quiet: the patron switched library, and
                //     `AuthDocumentLoader` re-drives the account if it returns.
                // Everything else (authDocumentFetchFailed, malformedAuthDocument,
                // accountNotFound) means the document will not arrive, which is a
                // genuine registration failure and must stay visible.
                switch Self.disposition(forReadinessFailure: error) {
                case .quiet:
                    Log.info(#file, "[FCM_REG] deferred (expected): \(error) — a later auth-doc drive resolves this and the next trigger registers")
                    return
                case .residual:
                    Log.warn(#file, "[FCM_REG] deferred: account still not ready after \(Self.accountReadinessTimeout)s — auth document wedged")
                    TPPErrorLogger.logError(
                        nil,
                        summary: "[FCM_REG] token registration deferred: account not ready within timeout",
                        metadata: [
                            "accountUUID": account.uuid,
                            "timeout": Self.accountReadinessTimeout,
                            "loadState": "\(account.loadState)"
                        ]
                    )
                    return
                case .report:
                    break
                }
                Log.warn(#file, "[FCM_REG] FAIL: account_load_failed — the authentication document will not arrive, so registration cannot proceed. error=\(error)")
                TPPErrorLogger.logError(
                    nil,
                    summary: "[FCM_REG] token registration deferred: account load failed",
                    metadata: [
                        "accountUUID": account.uuid,
                        "error": String(describing: error)
                    ]
                )
                return
            } catch {
                Log.warn(#file, "[FCM_REG] deferred: readiness wait ended without a terminal state. error=\(error)")
                return
            }
            // A1: re-resolve rather than trusting the captured instance.
            // `awaitReady` resolves on UUID-keyed STATE, but `getProfileDocument`
            // reads `details` off a specific Account OBJECT, and instance
            // identity is not stable (`docs/architecture/account-state-machine.md`)
            // — a `loadCatalogs` refresh mid-wait builds a fresh instance, writes
            // the terminal state from ITS details, and leaves the captured one
            // nil forever. Without this the original defect survives the fix and
            // reports "after the account was ready", which would be a lie.
            guard let live = self.accountsManager.currentAccount, live.uuid == account.uuid else {
                Log.info(#file, "[FCM_REG] SKIP: current account changed during the readiness wait — the new account's own trigger will register it")
                return
            }
            // QA blocking find: the `hasUpdatedToken` guard at the top of
            // `updateToken()` was read BEFORE the wait. Re-read it here — a
            // concurrent path may have confirmed registration while we waited,
            // and re-running the full checkTokenExists -> saveToken pipeline
            // would be duplicate traffic against the Circulation Manager.
            guard !live.hasUpdatedToken else {
                Log.info(#file, "[FCM_REG] SKIP: token was registered while waiting for readiness")
                return
            }
            guard live.details != nil else {
                Log.warn(#file, "[FCM_REG] FAIL: details_still_nil — the account reported ready but the live instance has no details")
                TPPErrorLogger.logError(
                    nil,
                    summary: "[FCM_REG] token registration deferred: details nil after readiness",
                    metadata: ["accountUUID": account.uuid]
                )
                return
            }
            await self.performTokenRegistration(for: live)
        }
    }

    /// Registration proper. Split out of `updateToken()` so the readiness gate
    /// above reads as one decision; the body below is unchanged behaviour.
    ///
    /// `async` because `getProfileDocument` is awaited now (PP-5301). The body
    /// is otherwise unchanged; `self` no longer needs the weak dance because
    /// the awaiting frame holds it.
    private func performTokenRegistration(for account: Account) async {
        let profileDocument = await account.getProfileDocument()
        guard let profileDocument else {
            // Resolve the auth state for the account this attempt is FOR.
            // Reading `currentUserAccount` here would report the wrong
            // library's state if a switch landed mid-fetch — the same
            // cross-account drift that made `markTokenRegistered` take an
            // explicit account.
            let currentAuthState = self.accountsManager.userAccount(for: account.uuid).authState

            // A signed-out patron has nothing to register. Deferring is the
            // CORRECT outcome, not a failure — the observed traffic includes
            // this case (a Settings library switch to a library the patron
            // is not signed in to). Reporting it as an error is noise that
            // hides the real failures.
            guard Self.shouldReportProfileFetchFailure(authState: currentAuthState) else {
                Log.info(#file, "[FCM_REG] SKIP: patron signed out — nothing to register")
                return
            }

            // Wording corrected in PP-4958. This previously blamed
            // "SAML-stale credentials, no credentials, network failure",
            // which is what this volume was triaged against for months and
            // is not what the device logs showed: the dominant cause was an
            // authentication document that had not loaded yet, so this
            // method returned on its first guard without issuing a request.
            // That is now gated by a readiness wait in `updateToken()`, so
            // reaching here means the profile fetch genuinely failed.
            Log.warn(#file, "[FCM_REG] FAIL: profile_doc_missing — /patrons/me/ returned nil after the account was ready. Suspect credentials or the network. authState=\(currentAuthState)")
            TPPErrorLogger.logError(
                nil,
                summary: "[FCM_REG] token registration deferred: profile fetch returned nil",
                metadata: [
                    // Same key spelling as every sibling non-fatal in this
                    // file. Support triages these together, and a
                    // Crashlytics query on `accountUUID` silently missed
                    // the arms that spelled it `uuid` or omitted it.
                    "accountUUID": account.uuid,
                    "authState": String(describing: currentAuthState),
                    "hasUpdatedToken": account.hasUpdatedToken
                ]
            )
            return
        }
        guard let endpointHref = profileDocument.linksWith(.deviceRegistration).first?.href,
              let endpointUrl = URL(string: endpointHref)
        else {
            Log.warn(#file, "[FCM_REG] FAIL: device_registration_link_missing — profile doc returned but had no deviceRegistration link. Library may not support push.")
            return
        }
        Messaging.messaging().token { [weak self] token, error in
            guard let self else { return }
            guard let token else {
                Log.warn(#file, "[FCM_REG] FAIL: fcm_token_unavailable — Firebase Messaging returned no token. error=\(error?.localizedDescription ?? "nil")")
                return
            }
            self.checkTokenExists(token, endpointUrl: endpointUrl) { [weak self] exists, _ in
                guard let self else { return }
                guard let exists = exists else {
                    // Inconclusive (non-200/404 status). Leave flag false so
                    // the next sign-in / account-change observer retries.
                    Log.warn(#file, "[FCM_REG] FAIL: exists_check_inconclusive — token-exists check returned non-200/non-404 (likely 401 or 5xx). Will retry on next sign-in / account-change.")
                    return
                }
                if exists {
                    Log.info(#file, "[FCM_REG] SUCCESS: token_already_registered — CM has the FCM token, no save needed")
                    self.markTokenRegistered(for: account)
                } else {
                    self.saveToken(token, endpointUrl: endpointUrl) { [weak self] succeeded in
                        guard let self else { return }
                        guard succeeded else {
                            Log.warn(#file, "[FCM_REG] FAIL: save_failed — PUT to deviceRegistration endpoint did not return 2xx. CM does not have the token. Will retry on next sign-in / account-change.")
                            return
                        }
                        Log.info(#file, "[FCM_REG] SUCCESS: token_saved — CM accepted the new FCM token (PUT 2xx)")
                        self.markTokenRegistered(for: account)
                    }
                }
            }
        }
    }

    /// Latches `hasUpdatedToken = true` once the FCM token is confirmed on the
    /// server, on the account the attempt was made for rather than the current
    /// one. Registration is asynchronous (PP-4958), so a library switch can land
    /// mid-attempt; latching the new current account would leave it marked
    /// registered and never retried.
    private func markTokenRegistered(for account: Account) {
        account.hasUpdatedToken = true
    }

    /// Pure success-decision helper used by `updateToken` and locked by unit
    /// tests. Returns true ONLY when the FCM token is confirmed registered with
    /// the Circulation Manager — i.e., every prerequisite succeeded AND either
    /// the token already exists on the server (no save needed) or a save
    /// attempt completed successfully. Returning false here means "leave the
    /// `hasUpdatedToken` flag false so the next sign-in observer can retry."
    ///
    /// - Parameters:
    ///   - profileDocument: the `/patrons/me/` document, or nil on auth failure.
    ///   - hasDeviceRegistrationLink: true iff the profile doc advertised a
    ///     device-registration link.
    ///   - fcmToken: the FCM token from Firebase Messaging, or nil if unavailable.
    ///   - existsResult: result of the token-exists check (true = already
    ///     registered, false = needs save, nil = inconclusive status).
    ///   - saveSucceeded: nil if save wasn't attempted (because exists==true or
    ///     an earlier guard short-circuited), otherwise true/false from PUT.
    static func shouldMarkTokenRegistered(
        profileDocumentPresent: Bool,
        hasDeviceRegistrationLink: Bool,
        fcmTokenPresent: Bool,
        existsResult: Bool?,
        saveSucceeded: Bool?
    ) -> Bool {
        guard profileDocumentPresent,
              hasDeviceRegistrationLink,
              fcmTokenPresent,
              let exists = existsResult else {
            return false
        }
        if exists { return true }
        return saveSucceeded == true
    }

    private func deleteToken(_ token: String, endpointUrl: URL) {
        guard let requestBody = TokenData(token: token).data else {
            return
        }
        var request = URLRequest(url: endpointUrl, applyingCustomUserAgent: true)
        request.httpMethod = "DELETE"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = networkExecutor.addBearerAndExecute(request) { _, response, error in
            if let error = error {
                TPPErrorLogger.logError(error,
                                        summary: "Couldn't delete token data",
                                        metadata: [
                                            "requestURL": endpointUrl,
                                            "tokenData": String(data: requestBody, encoding: .utf8) ?? "",
                                            "statusCode": (response as? HTTPURLResponse)?.statusCode ?? 0
                                        ]
                )
            }
        }
    }

    /// Five sign-out and library-removal call sites invoke this and return, so
    /// it keeps a synchronous signature and starts the work itself. The profile
    /// fetch is awaited inside (PP-5301), which is also what puts the
    /// continuation on the main actor rather than wherever the network layer
    /// delivered.
    func deleteToken(for account: Account) {
        Task {
            let profileDocument = await account.getProfileDocument()
            guard let endpointHref = profileDocument?.linksWith(.deviceRegistration).first?.href,
                  let endpointUrl = URL(string: endpointHref)
            else {
                return
            }
            Messaging.messaging().token { token, _ in
                if let token {
                    self.deleteToken(token, endpointUrl: endpointUrl)
                }
            }
        }
    }

    // MARK: - Messaging Delegate

    /// Notifies that the token is updated.
    /// Logs the token with a grep-able marker for automated test tooling.
    public func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken {
            Log.info(#file, "[FCM_TOKEN_REGISTERED] \(token)")
        }
        updateToken()
    }

    /// Returns the current FCM token, if available.
    func currentFCMToken() async -> String? {
        try? await Messaging.messaging().token()
    }

    // MARK: - Notification Center Delegate Methods

    /// Called when app receives a notification while in foreground.
    /// Shows the notification banner and triggers a throttled sync.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge, .sound])

        logNotificationReceived(notification.request.content, context: "foreground")

        // Sync with throttle to avoid redundant network calls
        // The registry already protects against concurrent syncs (.syncing state check)
        syncWithThrottle()
    }

    /// Called when user taps a notification to open the app.
    /// Triggers sync and navigates to Holds tab for hold-related notifications.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        logNotificationReceived(response.notification.request.content, context: "tapped")

        let userInfo = response.notification.request.content.userInfo
        let isHoldNotification = isHoldRelatedNotification(userInfo)

        // Sync to fetch fresh data from server
        // Uses throttle shared with applicationDidBecomeActive to avoid duplicate syncs
        // Note: Server may send notifications before OPDS feed reflects availability
        syncWithThrottle { [weak self] errorDocument, newBooks in
            if let errorDocument = errorDocument {
                Log.error(#file, "[Notification] Sync failed: \(errorDocument)")
            } else {
                Log.info(#file, "[Notification] Sync completed. New books: \(newBooks)")
                self?.logHeldBooksState()
            }
        }

        // Navigate to Holds tab for hold-related notifications. Taps are
        // user-initiated, so waiting on `awaitReady()` is acceptable; the
        // decision lives in `decideHoldNavigation(...)` so it is testable.
        if isHoldNotification {
            // Box the non-`Sendable` UNUserNotificationCenter completion handler so
            // it can cross into the `@Sendable @MainActor` navigation Task; it is
            // invoked exactly once, on the main actor. Mirrors `ImageCompletionBox`.
            let completionBox = NotificationCompletionBox(completionHandler)
            Task { @MainActor in
                let outcome = await Self.decideHoldNavigation(
                    currentAccount: self.accountsManager.currentAccount
                )
                switch outcome {
                case .navigate:
                    AppContainer.production().navigateToTabRoot(.holds)
                    Log.info(#file, "[Notification] Navigated to Holds tab")
                case .skipUnsupportedReservations:
                    Log.warn(#file, "[Notification] Cannot navigate to Holds - account doesn't support reservations")
                case .skipNoCurrentAccount:
                    Log.warn(#file, "[Notification] Cannot navigate to Holds - no current account")
                case .skipDetailsFailed:
                    Log.warn(#file, "[Notification] Cannot navigate to Holds - awaitReady failed")
                }
                completionBox.call()
            }
        } else {
            completionHandler()
        }
    }

    // MARK: - Testable seam (Bucket A migration)
    //
    // `UNNotificationResponse` has no public constructor, so the "navigate to
    // Holds for this account state?" decision is extracted here for tests.

    /// Navigation decision for a hold-related notification tap.
    enum HoldNavigationOutcome: Equatable {
        /// Navigate to the Holds tab.
        case navigate
        /// Skip navigation — the current account does not support
        /// reservations (still loaded, just not enabled).
        case skipUnsupportedReservations
        /// Skip navigation — no current account.
        case skipNoCurrentAccount
        /// Skip navigation — awaitReady() failed (e.g. `.detailsFailed`).
        case skipDetailsFailed
    }

    /// Decide whether to navigate to Holds for a hold-related
    /// notification tap, awaiting the account's state machine instead of
    /// reading raw `details?`. This is the Bucket A migration's
    /// testable seam — `userNotificationCenter(...)` delegates the
    /// account-state check here, then performs side-effecting navigation
    /// on the `.navigate` outcome.
    ///
    /// - Parameter currentAccount: the account to check; pass
    ///   `accountsManager.currentAccount` from production.
    /// - Returns: navigation outcome; caller performs the actual
    ///   `tabRouterHub.navigate(to: .holds)` side effect on `.navigate`.
    static func decideHoldNavigation(currentAccount: Account?) async -> HoldNavigationOutcome {
        guard let currentAccount = currentAccount else {
            return .skipNoCurrentAccount
        }
        let details: AccountDetails
        do {
            details = try await currentAccount.awaitReady()
        } catch {
            return .skipDetailsFailed
        }
        return details.supportsReservations ? .navigate : .skipUnsupportedReservations
    }

    // MARK: - Sync Throttling

    /// Shared throttle key - same as TPPAppDelegate.syncIfUserHasHolds
    /// Ensures notification sync and foreground sync don't duplicate each other
    private static let lastSyncTimestampKey = "lastForegroundSyncTimestamp"
    private static let syncThrottleSeconds: TimeInterval = 30

    /// Syncs the book registry with throttling to prevent redundant network calls.
    /// Uses the same throttle as applicationDidBecomeActive to coordinate syncs.
    private func syncWithThrottle(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
        // Skip if user isn't authenticated
        guard AppContainer.production().accountsManager.currentUserAccount.hasCredentials() else {
            completion?(nil, false)
            return
        }

        // Check throttle
        let lastSync = UserDefaults.standard.double(forKey: Self.lastSyncTimestampKey)
        let now = Date().timeIntervalSince1970

        guard (now - lastSync) > Self.syncThrottleSeconds else {
            Log.debug(#file, "[Notification Sync] Skipped - synced recently")
            completion?(nil, false)
            return
        }

        // Update timestamp before sync to prevent concurrent triggers
        UserDefaults.standard.set(now, forKey: Self.lastSyncTimestampKey)

        Log.info(#file, "[Notification Sync] Starting sync")
        bookRegistry.sync(completion: completion)
    }

    // MARK: - Notification Classification

    /// Event types sent by the Circulation Manager backend.
    /// See: circulation/src/palace/manager/celery/tasks/notifications.py
    enum NotificationEventType: String {
        case holdAvailable = "HoldAvailable"
        case holdRemoved = "HoldRemoved"
        case loanExpiry = "LoanExpiry"
        case loanRemoved = "LoanRemoved"

        var isHoldRelated: Bool {
            switch self {
            case .holdAvailable, .holdRemoved: return true
            case .loanExpiry, .loanRemoved: return false
            }
        }
    }

    /// Parses the event type from a push notification's userInfo.
    ///
    /// The CM backend sends `event_type` (e.g. "HoldAvailable", "LoanExpiry").
    /// Note: `userInfo["type"]` is the book's identifier type (e.g. "ISBN"),
    /// NOT the notification type — do not use it for routing.
    private func eventType(from userInfo: [AnyHashable: Any]) -> NotificationEventType? {
        guard let rawType = userInfo["event_type"] as? String else { return nil }
        return NotificationEventType(rawValue: rawType)
    }

    /// Determines if a notification is related to holds/reservations.
    ///
    /// Checks the `event_type` field from the CM backend payload first,
    /// then falls back to keyword matching on the notification text for
    /// local test notifications or non-standard payloads.
    private func isHoldRelatedNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        // Primary: check the CM backend's event_type field
        if let event = eventType(from: userInfo) {
            return event.isHoldRelated
        }

        // Fallback: keyword match on notification text (covers local test
        // notifications and any non-standard push payloads)
        if let aps = userInfo["aps"] as? [String: Any],
           let alert = aps["alert"] as? [String: Any] {
            let title = (alert["title"] as? String)?.lowercased() ?? ""
            let body = (alert["body"] as? String)?.lowercased() ?? ""
            let keywords = ["available", "ready", "hold", "reservation"]
            return keywords.contains { title.contains($0) || body.contains($0) }
        }

        // For local notifications with our test userInfo format
        if let type = userInfo["event_type"] as? String {
            return type.lowercased().contains("hold")
        }

        // Default: assume hold-related to ensure navigation on unknown payloads
        return true
    }

    // MARK: - Debug Logging

    /// Logs notification details for debugging
    private func logNotificationReceived(_ content: UNNotificationContent, context: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        Log.info(#file, """
      [Notification] Received (\(context)) at \(timestamp)
        Title: \(content.title)
        Body: \(content.body)
        UserInfo: \(content.userInfo)
      """)
    }

    /// Logs current held books state for debugging availability sync issues
    private func logHeldBooksState() {
        let heldBooks = bookRegistry.heldBooks
        Log.info(#file, "[Notification] Held books count: \(heldBooks.count)")

        for book in heldBooks {
            var status = "unknown"
            var position: UInt = 0

            book.defaultAcquisition?.availability.match(unavailable: 
                { _ in status = "unavailable" },
                limited: { _ in status = "limited" },
                unlimited: { _ in status = "unlimited" },
                reserved: { reserved in
                    status = "reserved"
                    position = reserved.holdPosition
                },
                ready: { _ in status = "READY" }
            )

            Log.info(#file, "[Notification] '\(book.title)' - \(status), position: \(position)")
        }
    }

    // MARK: - Local Hold Notifications

    /// Requests notification authorization from the user.
    /// Called when placing a hold so the user can receive availability notifications.
    class func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.badge, .sound, .alert]) { granted, error in
            Log.info(#file, "Notification Authorization: granted=\(granted), error=\(error?.localizedDescription ?? "nil")")
        }
    }

    /// Compares cached book availability with new data to detect when a hold becomes ready.
    /// Creates a local notification if a book transitions from "reserved" to "ready".
    ///
    /// Called by `TPPBookRegistry.updateBook()` during sync. If local notifications appear
    /// before the book is actually borrowable, it indicates the server OPDS feed returned
    /// "ready" status before the book was available (server-side timing issue).
    ///
    /// - Parameters:
    ///   - cachedRecord: The previously cached book record
    ///   - newBook: The newly fetched book data
    class func compareAvailability(cachedRecord: TPPBookRegistryRecord, andNewBook newBook: TPPBook) {
        var wasOnHold = false
        var isNowReady = false
        var oldStatus = "unknown"
        var newStatus = "unknown"
        var holdPosition: UInt = 0

        let oldAvail = cachedRecord.book.defaultAcquisition?.availability
        oldAvail?.match(unavailable: 
            { _ in oldStatus = "unavailable" },
            limited: { _ in oldStatus = "limited" },
            unlimited: { _ in oldStatus = "unlimited" },
            reserved: { reserved in
                oldStatus = "reserved (pos: \(reserved.holdPosition))"
                holdPosition = reserved.holdPosition
                wasOnHold = true
            },
            ready: { _ in oldStatus = "ready" }
        )

        let newAvail = newBook.defaultAcquisition?.availability
        newAvail?.match(unavailable: 
            { _ in newStatus = "unavailable" },
            limited: { _ in newStatus = "limited" },
            unlimited: { _ in newStatus = "unlimited" },
            reserved: { reserved in newStatus = "reserved (pos: \(reserved.holdPosition))" },
            ready: { _ in
                newStatus = "ready"
                isNowReady = true
            }
        )

        // Log availability changes for debugging
        if oldStatus != newStatus {
            Log.info(#file, "[Hold Availability] '\(newBook.title)' changed: \(oldStatus) → \(newStatus)")
        }

        if wasOnHold && isNowReady {
            Log.info(#file, "[Hold Notification] Creating for '\(newBook.title)' - was position \(holdPosition), now ready")
            createNotificationForReadyCheckout(book: newBook)
        }
    }

    /// Updates the app icon badge to show the count of holds ready to borrow.
    /// Called after sync to reflect current ready-to-borrow count.
    ///
    /// - Parameter heldBooks: Array of books currently on hold
    class func updateAppIconBadge(heldBooks: [TPPBook]) {
        var readyCount = 0
        for book in heldBooks {
            book.defaultAcquisition?.availability.match(unavailable: 
                nil,
                limited: nil,
                unlimited: nil,
                reserved: nil,
                ready: { _ in readyCount += 1 }
            )
        }
        Task { @MainActor in
            if UIApplication.shared.applicationIconBadgeNumber != readyCount {
                UIApplication.shared.applicationIconBadgeNumber = readyCount
            }
        }
    }

    /// Determines if a background fetch is needed based on held books count.
    /// Skips expensive network operations if user has no holds.
    ///
    /// - Returns: `true` if the user has held books and should fetch updates
    class func backgroundFetchIsNeeded() -> Bool {
        let count = AppContainer.production().bookRegistry.heldBooks.count
        Log.info(#file, "[Background Fetch] Held books: \(count)")
        return count > 0
    }

    /// Creates a local notification when a hold becomes ready to checkout.
    ///
    /// - Parameter book: The book that is now ready to borrow
    private class func createNotificationForReadyCheckout(book: TPPBook) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = Strings.UserNotifications.downloadReady
            content.body = NSLocalizedString("The title you reserved, \(book.title), is available.", comment: "")
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = HoldNotificationCategoryIdentifier
            content.userInfo = ["bookID": book.identifier]

            let request = UNNotificationRequest(
                identifier: book.identifier,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error = error {
                    TPPErrorLogger.logError(
                        error as NSError,
                        summary: "Error creating notification for ready checkout",
                        metadata: ["book": book.loggableDictionary()]
                    )
                }
            }
        }
    }
}

// MARK: - NotificationCompletionBox

/// Carries the non-`Sendable` `UNUserNotificationCenter` completion handler across
/// the `@Sendable @MainActor` hold-navigation Task in
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Invoked exactly
/// once, on the main actor, never concurrently — so `@unchecked Sendable` is sound.
/// Mirrors `ImageCompletionBox` / `CarPlayImageCompletionBox`.
private final class NotificationCompletionBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
