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
// `@preconcurrency`: Firebase Messaging's completion handlers (`token { }`) and
// the `MessagingDelegate` protocol carry `@Sendable`/isolation expectations that
// `NotificationService` (a non-Sendable `@objcMembers` singleton whose callbacks
// run on Firebase's own queues) cannot satisfy without a class-level `@MainActor`
// decision — which is intentionally deferred here (the class is called from the
// off-main book-registry sync path and from deferred critical-path modules).
// `@preconcurrency` silences the pre-Swift-6-annotated-API warnings without
// changing behavior.
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
// Swift 6 `complete` — `@unchecked Sendable` invariant: `self` is captured into the
// Firebase Messaging `@Sendable` completion handlers, the `@MainActor` notification
// Tasks, and the `.main` NotificationCenter observers. The immutable deps
// (`notificationCenter`, `accountsManager`, `networkExecutor`, `bookRegistry`,
// `skipsProductionAuthSubscription`) are all `let`s over Sendable types; the only two
// mutable `var`s (`authStateSubscription`, `lastObservedAuthState`) are guarded by
// `authStateLock`. This also makes the `static let shared` singleton concurrency-safe.
// The class-level `@MainActor` alternative is intentionally deferred (see the
// `@preconcurrency import FirebaseMessaging` note) because callbacks run off-main.
// Documented invariant, not a bare waiver.
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

    private let notificationCenter = UNUserNotificationCenter.current()
    private let accountsManager: AccountsManager
    private let networkExecutor: TPPNetworkExecutor
    private let bookRegistry: TPPBookRegistryProvider

    /// Guards the two mutable `var`s below (`authStateSubscription`,
    /// `lastObservedAuthState`) so the class can be `@unchecked Sendable` (see the
    /// type declaration). Both were previously main-confined by the `@MainActor`
    /// `UserAccountPublisher` emission, but the class-level `@MainActor` decision is
    /// deliberately deferred (Firebase callbacks run off-main), so an explicit lock
    /// makes the confinement sound under `complete` rather than assumed.
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

        // swarm_f3b9b087 item #6: subscribe to the existing
        // `UserAccountPublisher.shared.authStateDidChangePublisher` (the
        // same surface `HoldsViewModel` and `MyBooksViewModel` already
        // consume) so that when stale credentials recover to `.loggedIn`,
        // we re-attempt FCM token registration. Without this, a patron
        // who briefly entered `.credentialsStale` (e.g. SAML cookie
        // expired but bearer still fine, then re-auth) would never
        // re-register their FCM token until app cold-launch / sign-out /
        // library switch — and the Circulation Manager would never push
        // hold-availability notifications.
        //
        // The hop into `MainActor` is required because
        // `UserAccountPublisher.shared` is `@MainActor`-isolated and
        // `NotificationService.init()` is not. The hop happens once at
        // service construction; the resulting `AnyCancellable` is held
        // for the service's lifetime.
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
        onAuthStateRetryRequested: @escaping () -> Void
    ) {
        self.accountsManager = AppContainer.production().accountsManager
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

    /// Sends FCM to the backend
    ///
    /// Update token when user account changes.
    ///
    /// Why `hasUpdatedToken` is set only on confirmed success (HelpSpot 17680):
    /// previously the flag was latched optimistically before `/patrons/me/` was
    /// even called. When SAML credentials had gone stale, the profile fetch
    /// returned nil, the device-registration endpoint was never resolved, and
    /// the FCM token was never sent to the Circulation Manager — so the CM
    /// could not push hold-availability notifications. The flag stayed `true`,
    /// blocking every subsequent retry until app cold-launch / sign-out / library
    /// switch reset it. Now the flag is set only when the token is confirmed
    /// registered on the server (already-exists OR save succeeded).
    func updateToken() {
        guard !(accountsManager.currentAccount?.hasUpdatedToken ?? false) else {
            return
        }

        // [FCM_REG] grep marker for support-collected logs. Each branch
        // below logs its outcome with this prefix so a sysdiagnose from a
        // patron complaining about missing hold notifications can be
        // searched for the exact step that blocked registration. The CM
        // is blind to the SAML-stale-zero-token case (no metric surfaces
        // it server-side per the cross-platform audit on 2026-05-05) so
        // these client-side logs are the canonical signal.
        let authState = accountsManager.currentUserAccount.authState
        Log.info(#file, "[FCM_REG] updateToken start — authState=\(authState)")

        accountsManager.currentAccount?.getProfileDocument { [weak self] profileDocument in
            guard let self else { return }
            guard let profileDocument else {
                let currentAuthState = self.accountsManager.currentUserAccount.authState
                Log.warn(#file, "[FCM_REG] FAIL: profile_doc_missing — /patrons/me/ returned nil. Common causes: SAML-stale credentials, no credentials, network failure. authState=\(currentAuthState)")
                // swarm_f3b9b087 item #6: emit a Crashlytics non-fatal so we
                // can measure the gap server-side. The auth-state-change
                // subscription installed in `init()` will retry once
                // credentials recover; the non-fatal proves the deferral
                // happened and lets support diff against the recovery edge.
                TPPErrorLogger.logError(
                    nil,
                    summary: "[FCM_REG] token registration deferred: profile fetch returned nil",
                    metadata: [
                        "authState": String(describing: currentAuthState),
                        "hasUpdatedToken": self.accountsManager.currentAccount?.hasUpdatedToken ?? false
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
                        self.markTokenRegistered()
                    } else {
                        self.saveToken(token, endpointUrl: endpointUrl) { [weak self] succeeded in
                            guard let self else { return }
                            guard succeeded else {
                                Log.warn(#file, "[FCM_REG] FAIL: save_failed — PUT to deviceRegistration endpoint did not return 2xx. CM does not have the token. Will retry on next sign-in / account-change.")
                                return
                            }
                            Log.info(#file, "[FCM_REG] SUCCESS: token_saved — CM accepted the new FCM token (PUT 2xx)")
                            self.markTokenRegistered()
                        }
                    }
                }
            }
        }
    }

    /// Latches `hasUpdatedToken = true` on the account once the FCM token is
    /// confirmed live on the server. Centralized so the success contract has a
    /// single set-site (see `updateToken`'s doc comment for the why).
    private func markTokenRegistered() {
        accountsManager.currentAccount?.hasUpdatedToken = true
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

    func deleteToken(for account: Account) {
        account.getProfileDocument { profileDocument in
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

        // Navigate to Holds tab for hold-related notifications.
        //
        // Bucket A migration: notification taps are user-initiated, so the
        // `awaitReady()` window is acceptable. The decision logic is
        // factored into the static `decideHoldNavigation(...)` seam below
        // so the swarm Phase 1 state-machine tests can pin every branch
        // (`.detailsLoaded` + supports / does-not-support, `.detailsFailed`,
        // nil-account) without a `UNNotificationResponse` round-trip.
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
                    AppContainer.production().tabRouterHub.navigate(to: .holds)
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
    // The `userNotificationCenter(...didReceive...)` callback above is
    // hard to unit-test directly — it requires a real
    // `UNNotificationResponse` (no public constructor) and reaches into
    // `AppContainer.production().tabRouterHub` for navigation. The
    // pure-behavior logic for "should I navigate to Holds for this
    // account state?" is extracted here so the swarm Phase 1 state-machine
    // tests can pin every branch without an `UNUserNotificationCenter`
    // round-trip.

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
