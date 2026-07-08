import Foundation
import PalaceLogging
import PalaceKeychain
import PalaceNetwork

private enum StorageKey: String {
    // .barcode, .PIN, .authToken became legacy, as storage for those types was moved into .credentials enum

    case authorizationIdentifier = "TPPAccountAuthorization"
    case barcode = "TPPAccountBarcode" // legacy
    case PIN = "TPPAccountPIN" // legacy
    case adobeToken = "TPPAccountAdobeTokenKey"
    case licensor = "TPPAccountLicensorKey"
    case patron = "TPPAccountPatronKey"
    case authToken = "TPPAccountAuthTokenKey" // legacy
    case adobeVendor = "TPPAccountAdobeVendorKey"
    case provider = "TPPAccountProviderKey"
    case userID = "TPPAccountUserIDKey"
    case deviceID = "TPPAccountDeviceIDKey"
    case credentials = "TPPAccountCredentialsKey"
    case authDefinition = "TPPAccountAuthDefinitionKey"
    case cookies = "TPPAccountAuthCookiesKey"
    case authState = "TPPAccountAuthStateKey"

    func keyForLibrary(uuid libraryUUID: String?) -> String {
        guard
            // historically user data for NYPL has not used keys that contain the
            // library UUID.
            let libraryUUID = libraryUUID,
            libraryUUID != AppContainer.production().accountsManager.tppAccountUUID else {
            return self.rawValue
        }

        return "\(self.rawValue)_\(libraryUUID)"
    }
}

/// Consumers that need the needsAuth query without pulling in the full
/// TPPUserAccount type.
///
/// Historically this protocol also exposed `sharedAccount(libraryUUID:)` as a
/// singleton entry point. Production callers have moved to
/// `AccountsManager.userAccount(for:)` / `currentUserAccount`; the class-level
/// `sharedAccount` helpers on `TPPUserAccount` are retained as thin delegates
/// for a handful of test call sites and are scheduled for removal once those
/// are migrated.
@objc protocol TPPUserAccountProvider: NSObjectProtocol {
    var needsAuth: Bool { get }
}

@objcMembers class TPPUserAccount: NSObject, TPPUserAccountProvider, @unchecked Sendable {
    // `@unchecked Sendable` invariant — every mutable field is synchronized:
    //   • Keychain-backed state (`_authorizationIdentifier`, `_credentials`, …) is
    //     serialized through `accountInfoQueue` inside each `TPPKeychainVariable`.
    //   • The three plain control vars (`_notifyAccountChange`, `_signInGeneration`,
    //     `_sessionIdentifier`) are guarded by `controlLock`. They deliberately do
    //     NOT use `accountInfoQueue`: their setters run from inside `atomicUpdate`'s
    //     `accountInfoQueue.sync(flags:.barrier)` block (the sign-in pipeline —
    //     `setAuthToken`/`credentials=` rotate `sessionIdentifier`,
    //     `setAuthDefinitionWithoutUpdate` writes `notifyAccountChange`), so routing
    //     them through that serial queue would re-enter it and deadlock. `controlLock`
    //     is a non-recursive leaf lock with no ordering cycle against `accountInfoQueue`.
    //   • `let` fields (`libraryUUID`, `boundLibraryUUID`, `accountInfoQueue`,
    //     `controlLock`) are immutable; `lazy var` keychain variables are effectively
    //     immutable after first access and internally queue-synchronized.
    private let accountInfoQueue: DispatchQueue
    private let controlLock = NSLock()
    private lazy var keychainTransaction = TPPKeychainVariableTransaction(accountInfoQueue: accountInfoQueue)

    private var _notifyAccountChange: Bool = true
    private var notifyAccountChange: Bool {
        get { controlLock.lock(); defer { controlLock.unlock() }; return _notifyAccountChange }
        set { controlLock.lock(); _notifyAccountChange = newValue; controlLock.unlock() }
    }

    /// Always equal to `libraryUUID`. Kept as a separate property for
    /// backwards-compat with older call sites that read it to assert the
    /// account is bound to a specific library (per-account-isolation tests).
    let boundLibraryUUID: String?

    /// Incremented by `cancelPendingSignOut()` each time the user
    /// signs in, so that a stale DRM deauthorization callback can detect
    /// that re-authentication occurred and skip credential cleanup.
    /// Backed by `_signInGeneration` under `controlLock`. Kept settable (not
    /// `private(set)`) because `TPPUserAccountMock.removeAll()` writes `= 0`;
    /// the atomic `+= 1` at the sign-out site uses `incrementSignInGeneration()`.
    private var _signInGeneration: Int = 0
    var signInGeneration: Int {
        get { controlLock.lock(); defer { controlLock.unlock() }; return _signInGeneration }
        set { controlLock.lock(); _signInGeneration = newValue; controlLock.unlock() }
    }

    /// Atomically increments the sign-in generation as a single locked
    /// read-modify-write, so a concurrent reader on the sign-out path never
    /// observes a torn `+= 1`. Use this instead of `signInGeneration += 1`
    /// (which would be a non-atomic get-then-set across two lock acquisitions).
    func incrementSignInGeneration() {
        controlLock.lock()
        _signInGeneration += 1
        controlLock.unlock()
    }

    /// An opaque, per-sign-in identifier that rotates each time a successful
    /// sign-in completes (i.e. new credentials are written). This is purely
    /// observable for defense-in-depth tests verifying session-fixation
    /// protection — it is NOT used for any authentication, authorization, or
    /// network purpose and must never be persisted or transmitted.
    /// Exposed as `String` so it is Obj-C friendly via `@objcMembers`.
    /// Backed by `_sessionIdentifier` under `controlLock`.
    private var _sessionIdentifier: String = UUID().uuidString
    public private(set) var sessionIdentifier: String {
        get { controlLock.lock(); defer { controlLock.unlock() }; return _sessionIdentifier }
        set { controlLock.lock(); _sessionIdentifier = newValue; controlLock.unlock() }
    }

    // MARK: - Initializers

    /// Creates an account bound to a specific library. Keys are computed once
    /// (lazily on first access) from the immutable `libraryUUID` and never
    /// change for the lifetime of the instance.
    ///
    /// Always construct instances via `AccountsManager.userAccount(for:)` so
    /// there is one cached instance per library — direct `init(libraryUUID:)`
    /// from production code will silently bypass the cache and risk duplicate
    /// instances for the same library.
    init(libraryUUID: String) {
        self.libraryUUID = libraryUUID
        self.boundLibraryUUID = libraryUUID
        self.accountInfoQueue = DispatchQueue(label: "TPPUserAccount.\(libraryUUID)")
        super.init()
    }

    /// Library this account is bound to. Immutable.
    let libraryUUID: String?

    var authDefinition: AccountDetails.Authentication? {
        get {
            guard let read = _authDefinition.read() else {
                // Phase 2 (swarm_81b5099e follow-up): state-machine-aware
                // fallback. Returns `nil` until the resolved account is
                // `.detailsLoaded` — same nil-tolerance as the legacy
                // `account.details?` read, but no longer races a partially-
                // loaded auth doc. The fallback only fires when no auth
                // definition was previously written (e.g. cold-launch
                // before sign-in), so blocking on the gate is moot anyway.
                let accountsManager = AppContainer.production().accountsManager
                let candidate: Account?
                if let libraryUUID = self.libraryUUID {
                    candidate = accountsManager.account(libraryUUID)
                } else {
                    candidate = accountsManager.currentAccount
                }
                guard let account = candidate,
                      case .detailsLoaded(let details) = account.loadState else {
                    return nil
                }
                return details.auths.first
            }
            return read
        }
        set {
            guard let newValue = newValue else { return }
            _authDefinition.write(newValue)

            DispatchQueue.main.async {
                let accountsManager = AppContainer.production().accountsManager
                var mainFeed = URL(string: accountsManager.currentAccount?.catalogUrl ?? "")
                let resolveFn = {
                    AppContainer.production().settings.accountMainFeedURL = mainFeed
                    UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()

                    if self.notifyAccountChange {
                        NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange, object: nil)
                    }

                    self.notifyAccountChange = true
                }

                if self.needsAgeCheck {
                    accountsManager.ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: self,
                                                                                       currentLibraryAccountProvider: accountsManager) { [weak self] meetsAgeRequirement in
                        DispatchQueue.main.async {
                            mainFeed = self?.authDefinition?.coppaURL(isOfAge: meetsAgeRequirement)
                            resolveFn()
                        }
                    }
                } else {
                    resolveFn()
                }
            }

            notifyAccountDidChange()
        }
    }

    var credentials: TPPCredentials? {
        get {
            var credentials = _credentials.read()

            if credentials == nil {
                if let barcode = legacyBarcode, let pin = legacyPin {
                    credentials = .barcodeAndPin(barcode: barcode, pin: pin)
                    keychainTransaction.perform {
                        _credentials.write(credentials)
                        _barcode.write(nil)
                        _pin.write(nil)
                    }
                } else if let authToken = legacyAuthToken {
                    credentials = .token(authToken: authToken, barcode: legacyBarcode, pin: legacyPin)
                    keychainTransaction.perform {
                        _credentials.write(credentials)
                        _authToken.write(nil)
                    }
                }
            }

            return credentials
        }
        set {
            guard let newValue = newValue else { return }
            _credentials.write(newValue)

            // Rotate the observable session identifier on successful sign-in.
            // Purely for test observation of session-fixation defense; not used
            // for auth.
            sessionIdentifier = UUID().uuidString

            if case let .barcodeAndPin(barcode: userBarcode, pin: _) = newValue {
                TPPErrorLogger.setUserID(userBarcode)
            }

            notifyAccountDidChange()
        }
    }

    // MARK: - Test/Legacy Compatibility Shims
    //
    // These class methods are thin delegates to the per-account path. They are
    // kept for a small number of test call sites that construct mocks via the
    // legacy singleton-style API. No shared state is involved — each call
    // resolves to the per-library instance owned by AccountsManager. Remove
    // once every test call site has been migrated to
    // `appContainer.accountsManager.userAccount(for:)`.

    @available(*, deprecated, message: "Use appContainer.accountsManager.userAccount(for:) or .currentUserAccount")
    class func sharedAccount() -> TPPUserAccount {
        return AppContainer.production().accountsManager.currentUserAccount
    }

    @available(*, deprecated, message: "Use appContainer.accountsManager.userAccount(for:) or .currentUserAccount")
    class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        let accountsManager = AppContainer.production().accountsManager
        let id = libraryUUID ?? accountsManager.currentAccountId ?? ""
        guard !id.isEmpty else { return accountsManager.currentUserAccount }
        return accountsManager.userAccount(for: id)
    }

    func setAuthDefinitionWithoutUpdate(authDefinition: AccountDetails.Authentication?) {
        notifyAccountChange = false
        self.authDefinition = authDefinition
    }

    private func notifyAccountDidChange() {
        Task { @MainActor in
            UserAccountPublisher.shared.updateState(from: self)
        }
        NotificationCenter.default.post(
            name: Notification.Name.TPPUserAccountDidChange,
            object: self
        )
    }

    // MARK: - Storage
    private lazy var _authorizationIdentifier: TPPKeychainVariable<String> = StorageKey.authorizationIdentifier
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _adobeToken: TPPKeychainVariable<String> = StorageKey.adobeToken
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _licensor: TPPKeychainVariable<[String: Any]> = StorageKey.licensor
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _patron: TPPKeychainVariable<[String: Any]> = StorageKey.patron
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _adobeVendor: TPPKeychainVariable<String> = StorageKey.adobeVendor
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _provider: TPPKeychainVariable<String> = StorageKey.provider
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _userID: TPPKeychainVariable<String> = StorageKey.userID
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _deviceID: TPPKeychainVariable<String> = StorageKey.deviceID
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _credentials: TPPKeychainCodableVariable<TPPCredentials> = StorageKey.credentials
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainCodableVariable(with: accountInfoQueue)
    private lazy var _authDefinition: TPPKeychainCodableVariable<AccountDetails.Authentication> = StorageKey.authDefinition
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainCodableVariable(with: accountInfoQueue)
    private lazy var _cookies: TPPKeychainVariable<[HTTPCookie]> = StorageKey.cookies
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _authState: TPPKeychainCodableVariable<TPPAccountAuthState> = StorageKey.authState
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainCodableVariable(with: accountInfoQueue)

    // Legacy
    private lazy var _barcode: TPPKeychainVariable<String> = StorageKey.barcode
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _pin: TPPKeychainVariable<String> = StorageKey.PIN
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)
    private lazy var _authToken: TPPKeychainVariable<String> = StorageKey.authToken
        .keyForLibrary(uuid: libraryUUID)
        .asKeychainVariable(with: accountInfoQueue)

    // MARK: - Check (delegates to UserAccountAuthHelper)

    func hasBarcodeAndPIN() -> Bool {
        UserAccountAuthHelper.hasBarcodeAndPIN(credentials: credentials)
    }

    func hasAuthToken() -> Bool {
        UserAccountAuthHelper.hasAuthToken(credentials: credentials)
    }

    func isTokenRefreshRequired() -> Bool {
        UserAccountAuthHelper.isTokenRefreshRequired(
            authDefinition: authDefinition,
            credentials: credentials,
            username: username,
            pin: pin
        )
    }

    func hasAdobeToken() -> Bool { adobeToken != nil }
    func hasLicensor() -> Bool { licensor != nil }
    func hasCredentials() -> Bool { UserAccountAuthHelper.hasCredentials(credentials) }

    var catalogRequiresAuthentication: Bool {
        UserAccountAuthHelper.catalogRequiresAuthentication(authDefinition: authDefinition)
    }

    // MARK: - Legacy

    private var legacyBarcode: String? { return _barcode.read() }
    private var legacyPin: String? { return _pin.read() }
    var legacyAuthToken: String? { _authToken.read() }

    // MARK: - GET

    var barcode: String? { UserAccountAuthHelper.barcode(from: credentials) }
    var authorizationIdentifier: String? { _authorizationIdentifier.read() }
    var PIN: String? { UserAccountAuthHelper.pin(from: credentials) }

    var needsAuth: Bool { UserAccountAuthHelper.needsAuth(authDefinition: authDefinition) }
    var needsAgeCheck: Bool { UserAccountAuthHelper.needsAgeCheck(authDefinition: authDefinition) }

    var deviceID: String? { _deviceID.read() }
    var userID: String? { _userID.read() }
    var adobeVendor: String? { _adobeVendor.read() }
    var provider: String? { _provider.read() }
    var patron: [String: Any]? { _patron.read() }
    var adobeToken: String? { _adobeToken.read() }
    var licensor: [String: Any]? { _licensor.read() }
    var cookies: [HTTPCookie]? { _cookies.read() }

    var authState: TPPAccountAuthState {
        UserAccountAuthHelper.resolveAuthState(
            storedState: _authState.read(),
            hasCredentials: hasCredentials()
        )
    }

    var authToken: String? { UserAccountAuthHelper.authToken(from: _credentials.read()) }

    var authTokenHasExpired: Bool {
        UserAccountAuthHelper.isTokenExpired(credentials: credentials)
    }

    var authTokenNearExpiry: Bool {
        UserAccountAuthHelper.isTokenNearExpiry(credentials: credentials)
    }

    var patronFullName: String? {
        UserAccountAuthHelper.patronFullName(from: patron)
    }

    // MARK: - SET

    @objc(setBarcode:PIN:)
    func setBarcode(_ barcode: String, PIN: String) {
        credentials = .barcodeAndPin(barcode: barcode, pin: PIN)
    }

    @objc(setAdobeToken:patron:)
    func setAdobeToken(_ token: String, patron: [String: Any]) {
        keychainTransaction.perform {
            _adobeToken.write(token)
            _patron.write(patron)
        }
        notifyAccountDidChange()
    }

    @objc(setAdobeVendor:)
    func setAdobeVendor(_ vendor: String) {
        _adobeVendor.write(vendor)
        notifyAccountDidChange()
    }

    @objc(setAdobeToken:)
    func setAdobeToken(_ token: String) {
        _adobeToken.write(token)
        notifyAccountDidChange()
    }

    @objc(setLicensor:)
    func setLicensor(_ licensor: [String: Any]) {
        _licensor.write(licensor)
    }

    @objc(setAuthorizationIdentifier:)
    func setAuthorizationIdentifier(_ identifier: String) {
        _authorizationIdentifier.write(identifier)
    }

    @objc(setPatron:)
    func setPatron(_ patron: [String: Any]) {
        _patron.write(patron)
        notifyAccountDidChange()
    }

    @objc(setAuthToken::::)
    func setAuthToken(_ token: String, barcode: String?, pin: String?, expirationDate: Date?) {
        keychainTransaction.perform {
            _credentials.write(.token(authToken: token, barcode: barcode, pin: pin, expirationDate: expirationDate))
            // A fresh token is a successful auth signal. Flip authState to
            // .loggedIn now so silent re-auth paths (TokenRefreshInterceptor
            // OIDC/SAML refresh, OIDC callback handler) don't leave a
            // previously-set .credentialsStale flag persisted across launches.
            // Without this, the user is re-prompted to sign in on the next
            // cold start even though their token is valid — the responder's
            // self-heal block only fires when a subsequent 2xx response
            // happens to come back while this library is foregrounded.
            _authState.write(.loggedIn)
        }
        // Rotate the observable session identifier on successful sign-in.
        // Purely for test observation of session-fixation defense; not used
        // for auth.
        sessionIdentifier = UUID().uuidString
        notifyAccountDidChange()
    }

    @objc(setCookies:)
    func setCookies(_ cookies: [HTTPCookie]) {
        _cookies.write(cookies)
        notifyAccountDidChange()
    }

    @objc(setProvider:)
    func setProvider(_ provider: String) {
        _provider.write(provider)
        notifyAccountDidChange()
    }

    @objc(setUserID:)
    func setUserID(_ id: String) {
        _userID.write(id)
        notifyAccountDidChange()
    }

    @objc(setDeviceID:)
    func setDeviceID(_ id: String) {
        _deviceID.write(id)
        notifyAccountDidChange()
    }

    func setAuthState(_ state: TPPAccountAuthState) {
        Log.debug(#file, "Auth state changing from \(authState) to \(state)")
        _authState.write(state)

        Task { @MainActor in
            UserAccountPublisher.shared.updateState(from: self)
        }
        notifyAccountDidChange()
    }

    func markCredentialsStale() {
        guard authState == .loggedIn else {
            Log.debug(#file, "Cannot mark credentials stale - current state is \(authState)")
            return
        }
        setAuthState(.credentialsStale)
    }

    func markLoggedIn() {
        setAuthState(.loggedIn)
    }

    // MARK: - Cache Refresh

    /// Drops every keychain variable's in-memory cache so the next read pulls
    /// fresh from the keychain. Callers should invoke this when another
    /// process or another TPPUserAccount instance may have written under the
    /// same keys (sign-in pipeline, sign-out finalisation, SAML cookie
    /// rotation) and this instance's cached values could be stale.
    ///
    /// Historical note: the old implementation achieved this by assigning
    /// `libraryUUID = nil; libraryUUID = uuid`, which forced a cache flip via
    /// `updateKeychainKeys()`. That pattern required `libraryUUID` to be
    /// mutable and was the root cause of the "libraryUUID changed from X →
    /// nil → X" log thrash and the login-prompt-during-download race.
    private func invalidateAllKeychainCaches() {
        _authorizationIdentifier.invalidateCache()
        _adobeToken.invalidateCache()
        _licensor.invalidateCache()
        _patron.invalidateCache()
        _adobeVendor.invalidateCache()
        _provider.invalidateCache()
        _userID.invalidateCache()
        _deviceID.invalidateCache()
        _credentials.invalidateCache()
        _authDefinition.invalidateCache()
        _cookies.invalidateCache()
        _authState.invalidateCache()
        _barcode.invalidateCache()
        _pin.invalidateCache()
        _authToken.invalidateCache()
    }

    @discardableResult
    func refreshCredentialsFromKeychain() -> Bool {
        return accountInfoQueue.sync(flags: .barrier) {
            guard libraryUUID != nil else { return hasCredentials() }
            invalidateAllKeychainCaches()
            return hasCredentials()
        }
    }

    /// Event-driven credential-cache invalidation (CP-D2). Drops every keychain
    /// variable's in-memory cache so the next `credentialSnapshot()` /
    /// credential read pulls fresh from the keychain.
    ///
    /// `credentialSnapshot()` no longer invalidates the cache on every read (it
    /// relies on the write-through keychain cache + the one-instance-per-library
    /// invariant). Callers invoke this at the two boundaries where credential
    /// state can change out of band relative to this instance's cache:
    ///   1. Sign-out finalisation — handled inline by `removeAll()`.
    ///   2. Account switch — `AccountsManager.currentAccount.didSet` calls this
    ///      on the newly-current account so its first snapshot after the switch
    ///      reads fresh keychain state.
    /// It is defense-in-depth against any future non-instance / cross-process
    /// writer; in the normal single-instance path the write-through cache has
    /// already kept this instance coherent.
    func invalidateCredentialCaches() {
        accountInfoQueue.sync {
            invalidateAllKeychainCaches()
        }
    }

    // MARK: - Atomic Snapshot

    struct CredentialSnapshot {
        let hasCredentials: Bool
        let hasAuthToken: Bool
        let authState: TPPAccountAuthState
        let barcode: String?
        let pin: String?
        let authToken: String?
        let authDefinition: AccountDetails.Authentication?
        let cookies: [HTTPCookie]?
    }

    /// Instance-level snapshot — reads from this instance's keychain variables.
    /// On bound (per-account) instances the keys are immutable, so this is
    /// inherently race-free without needing a barrier.
    ///
    /// Cache coherence (CP-D2): this path deliberately does NOT invalidate the
    /// keychain caches on every read. Each `TPPKeychainVariable` is
    /// write-through (`write()` updates `cachedValue` AND persists), and
    /// production keeps exactly one `TPPUserAccount` instance per library UUID
    /// (`AccountsManager.userAccount(for:)` cache) — the instance that writes
    /// credentials (sign-in / sign-out via `setBarcode`/`setAuthToken`/
    /// `removeAll`) is the same instance every reader (`AccountDetailViewModel`,
    /// `TPPNetworkExecutor`, `TPPNetworkResponder`) reads through. So the cache
    /// is always coherent without dropping it on every request build. There is
    /// also no cross-process keychain writer (no app-groups / keychain-sharing /
    /// extensions in the entitlements), so per-read invalidation was pure
    /// overhead on the request hot path.
    ///
    /// Coherence at the two boundaries where credential state can change out of
    /// band relative to a given instance's cache is preserved by EVENT-DRIVEN
    /// invalidation instead: sign-out finalisation (`removeAll()`) and account
    /// switch (`AccountsManager.currentAccount.didSet` → `invalidateCredentialCaches()`).
    /// This removes the build-459 staleness (which came from a singleton writer
    /// vs. per-account reader split that no longer exists) without re-reading
    /// the keychain on every network request.
    func credentialSnapshot() -> CredentialSnapshot {
        return accountInfoQueue.sync {
            let creds = self.credentials
            let hasCreds = UserAccountAuthHelper.hasCredentials(creds)
            let hasToken = UserAccountAuthHelper.hasAuthToken(credentials: creds)
            let state = UserAccountAuthHelper.resolveAuthState(
                storedState: self._authState.read(),
                hasCredentials: hasCreds
            )

            return CredentialSnapshot(
                hasCredentials: hasCreds,
                hasAuthToken: hasToken,
                authState: state,
                barcode: UserAccountAuthHelper.barcode(from: creds),
                pin: UserAccountAuthHelper.pin(from: creds),
                authToken: UserAccountAuthHelper.authToken(from: creds),
                authDefinition: self.authDefinition,
                cookies: self._cookies.read()
            )
        }
    }

    /// Class-level snapshot that routes to the per-library instance owned by
    /// AccountsManager. Preserved for Obj-C callers and legacy tests that use
    /// `TPPUserAccount.credentialSnapshot(for:)` — internally it is just a
    /// thin forward to the safe per-account path, with no singleton mutation.
    class func credentialSnapshot(for libraryUUID: String?) -> CredentialSnapshot {
        let accountsManager = AppContainer.production().accountsManager
        let id = libraryUUID ?? accountsManager.currentAccountId ?? ""
        guard !id.isEmpty else {
            return CredentialSnapshot(
                hasCredentials: false,
                hasAuthToken: false,
                authState: .loggedOut,
                barcode: nil,
                pin: nil,
                authToken: nil,
                authDefinition: nil,
                cookies: nil
            )
        }
        return accountsManager.userAccount(for: id).credentialSnapshot()
    }

    // MARK: - Atomic Write

    /// Runs `block` under this account's barrier queue so multi-step writes
    /// (sign-in pipeline: credentials + tokens + cookies + state) are applied
    /// atomically relative to other readers. The `libraryUUID` parameter is
    /// preserved for backwards compatibility with callers that already pass
    /// it; it is validated against `self.libraryUUID` to catch cases where a
    /// caller passes a different library's UUID (which is always a bug now
    /// that instances are per-library).
    func atomicUpdate(for libraryUUID: String?,
                      _ block: (TPPUserAccount) -> Void) {
        if let libraryUUID = libraryUUID,
           let selfUUID = self.libraryUUID,
           libraryUUID != selfUUID {
            assertionFailure("atomicUpdate called with libraryUUID \(libraryUUID) on an account bound to \(selfUUID)")
        }
        accountInfoQueue.sync(flags: .barrier) {
            block(self)
        }
    }

    // MARK: - Remove

    func removeAll() {
        keychainTransaction.perform {
            _adobeToken.write(nil)
            _patron.write(nil)
            _adobeVendor.write(nil)
            _provider.write(nil)
            _userID.write(nil)
            _deviceID.write(nil)
            _authState.write(nil)

            keychainTransaction.perform {
                _authDefinition.write(nil)
                _credentials.write(nil)
                _cookies.write(nil)
                _authorizationIdentifier.write(nil)

                // remove legacy, just in case
                _barcode.write(nil)
                _pin.write(nil)
                _authToken.write(nil)
            }

            // CP-D2: event-driven cache invalidation on sign-out finalisation.
            // The write-through `write(nil)` calls above already left every
            // cache nil, but `credentialSnapshot()` no longer invalidates per
            // read — so drop the caches here too, synchronously and BEFORE the
            // `.TPPDidSignOut` notification posts. This guarantees any consumer
            // that reacts to sign-out (`AccountDetailViewModel.accountDidChange`,
            // and — critically — the `TPPNetworkResponder` 401-decision reading
            // `currentUserAccount.credentialSnapshot()`) can never observe a
            // stale "signed in" snapshot after sign-out has completed.
            invalidateAllKeychainCaches()
        }

        Task { @MainActor in
            UserAccountPublisher.shared.signOut()
        }
        notifyAccountDidChange()
        NotificationCenter.default.post(name: Notification.Name.TPPDidSignOut, object: nil)
    }
}

extension TPPUserAccount: TPPSignedInStateProvider {
    func isSignedIn() -> Bool {
        return hasCredentials()
    }
}

extension TPPUserAccount: NYPLBasicAuthCredentialsProvider {
    var username: String? {
        return barcode
    }

    var pin: String? {
        return PIN
    }
}
