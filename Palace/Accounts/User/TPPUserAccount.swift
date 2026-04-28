import Foundation
import PalaceLogging
import PalaceKeychain

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
            libraryUUID != AccountsManager.shared.tppAccountUUID else {
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

@objcMembers class TPPUserAccount: NSObject, TPPUserAccountProvider {
    private let accountInfoQueue: DispatchQueue
    private lazy var keychainTransaction = TPPKeychainVariableTransaction(accountInfoQueue: accountInfoQueue)
    private var notifyAccountChange: Bool = true

    /// Always equal to `libraryUUID`. Kept as a separate property for
    /// backwards-compat with older call sites that read it to assert the
    /// account is bound to a specific library (per-account-isolation tests).
    let boundLibraryUUID: String?

    /// PP-3819: Incremented by `cancelPendingSignOut()` each time the user
    /// signs in, so that a stale DRM deauthorization callback can detect
    /// that re-authentication occurred and skip credential cleanup.
    var signInGeneration: Int = 0

    /// An opaque, per-sign-in identifier that rotates each time a successful
    /// sign-in completes (i.e. new credentials are written). This is purely
    /// observable for defense-in-depth tests verifying session-fixation
    /// protection — it is NOT used for any authentication, authorization, or
    /// network purpose and must never be persisted or transmitted.
    /// Exposed as `String` so it is Obj-C friendly via `@objcMembers`.
    public private(set) var sessionIdentifier: String = UUID().uuidString

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
                if let libraryUUID = self.libraryUUID {
                    return AccountsManager.shared.account(libraryUUID)?.details?.auths.first
                }

                return AccountsManager.shared.currentAccount?.details?.auths.first
            }
            return read
        }
        set {
            guard let newValue = newValue else { return }
            _authDefinition.write(newValue)

            DispatchQueue.main.async {
                var mainFeed = URL(string: AccountsManager.shared.currentAccount?.catalogUrl ?? "")
                let resolveFn = {
                    AppContainer.production().settings.accountMainFeedURL = mainFeed
                    UIApplication.shared.delegate?.window??.tintColor = TPPConfiguration.mainColor()

                    if self.notifyAccountChange {
                        NotificationCenter.default.post(name: NSNotification.Name.TPPCurrentAccountDidChange, object: nil)
                    }

                    self.notifyAccountChange = true
                }

                if self.needsAgeCheck {
                    AccountsManager.shared.ageCheck.verifyCurrentAccountAgeRequirement(userAccountProvider: self,
                                                                                       currentLibraryAccountProvider: AccountsManager.shared) { [weak self] meetsAgeRequirement in
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
    // `AccountsManager.shared.userAccount(for:)`.

    @available(*, deprecated, message: "Use AccountsManager.shared.userAccount(for:) or .currentUserAccount")
    class func sharedAccount() -> TPPUserAccount {
        return AccountsManager.shared.currentUserAccount
    }

    @available(*, deprecated, message: "Use AccountsManager.shared.userAccount(for:) or .currentUserAccount")
    class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        let id = libraryUUID ?? AccountsManager.shared.currentAccountId ?? ""
        guard !id.isEmpty else { return AccountsManager.shared.currentUserAccount }
        return AccountsManager.shared.userAccount(for: id)
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
    /// Cache coherence: each `TPPKeychainVariable` caches its last-read value
    /// and only invalidates explicitly. Another instance of the same library
    /// (or a different process) may have written under the same keys, so we
    /// drop every cache before reading. Without this, the view model can read
    /// "signed in" state even after sign-out has completed (build 459 → HEAD
    /// regression).
    func credentialSnapshot() -> CredentialSnapshot {
        return accountInfoQueue.sync {
            if libraryUUID != nil {
                invalidateAllKeychainCaches()
            }
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
        let id = libraryUUID ?? AccountsManager.shared.currentAccountId ?? ""
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
        return AccountsManager.shared.userAccount(for: id).credentialSnapshot()
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
