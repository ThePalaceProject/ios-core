import Foundation

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

@objc protocol TPPUserAccountProvider: NSObjectProtocol {
    var needsAuth: Bool { get }

    static func sharedAccount(libraryUUID: String?) -> TPPUserAccount
}

@objcMembers class TPPUserAccount: NSObject, TPPUserAccountProvider {
    static private let shared = TPPUserAccount()
    private let accountInfoQueue = DispatchQueue(label: "TPPUserAccount.accountInfoQueue")
    private lazy var keychainTransaction = TPPKeychainVariableTransaction(accountInfoQueue: accountInfoQueue)
    private var notifyAccountChange: Bool = true

    /// PP-3819: Incremented by `cancelPendingSignOut()` each time the user
    /// signs in, so that a stale DRM deauthorization callback can detect
    /// that re-authentication occurred and skip credential cleanup.
    var signInGeneration: Int = 0

    var libraryUUID: String? {
        didSet {
            guard libraryUUID != oldValue else { return }

            Log.debug(#file, "libraryUUID changed from \(oldValue ?? "nil") to \(libraryUUID ?? "nil")")

            _authorizationIdentifier.key = StorageKey.authorizationIdentifier.keyForLibrary(uuid: libraryUUID)
            _adobeToken.key = StorageKey.adobeToken.keyForLibrary(uuid: libraryUUID)
            _licensor.key = StorageKey.licensor.keyForLibrary(uuid: libraryUUID)
            _patron.key = StorageKey.patron.keyForLibrary(uuid: libraryUUID)
            _adobeVendor.key = StorageKey.adobeVendor.keyForLibrary(uuid: libraryUUID)
            _provider.key = StorageKey.provider.keyForLibrary(uuid: libraryUUID)
            _userID.key = StorageKey.userID.keyForLibrary(uuid: libraryUUID)
            _deviceID.key = StorageKey.deviceID.keyForLibrary(uuid: libraryUUID)
            _credentials.key = StorageKey.credentials.keyForLibrary(uuid: libraryUUID)
            _authDefinition.key = StorageKey.authDefinition.keyForLibrary(uuid: libraryUUID)
            _cookies.key = StorageKey.cookies.keyForLibrary(uuid: libraryUUID)
            _authState.key = StorageKey.authState.keyForLibrary(uuid: libraryUUID)

            // Legacy
            _barcode.key = StorageKey.barcode.keyForLibrary(uuid: libraryUUID)
            _pin.key = StorageKey.PIN.keyForLibrary(uuid: libraryUUID)
            _authToken.key = StorageKey.authToken.keyForLibrary(uuid: libraryUUID)
        }
    }

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
                    TPPSettings.shared.accountMainFeedURL = mainFeed
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

            if case let .barcodeAndPin(barcode: userBarcode, pin: _) = newValue {
                TPPErrorLogger.setUserID(userBarcode)
            }

            notifyAccountDidChange()
        }
    }

    class func sharedAccount() -> TPPUserAccount {
        return sharedAccount(libraryUUID: AccountsManager.shared.currentAccountId)
    }

    class func sharedAccount(libraryUUID: String?) -> TPPUserAccount {
        shared.accountInfoQueue.sync(flags: .barrier) {
            if shared.libraryUUID != libraryUUID {
                shared.libraryUUID = libraryUUID
            }
        }
        return shared
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

    @discardableResult
    func refreshCredentialsFromKeychain() -> Bool {
        return accountInfoQueue.sync(flags: .barrier) {
            guard let uuid = libraryUUID else { return hasCredentials() }
            libraryUUID = nil
            libraryUUID = uuid
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
    }

    class func credentialSnapshot(for libraryUUID: String?) -> CredentialSnapshot {
        return shared.accountInfoQueue.sync(flags: .barrier) {
            if shared.libraryUUID != libraryUUID {
                shared.libraryUUID = libraryUUID
            }

            if let uuid = shared.libraryUUID {
                shared.libraryUUID = nil
                shared.libraryUUID = uuid
            }

            let creds = shared.credentials
            let hasCreds = UserAccountAuthHelper.hasCredentials(creds)
            let hasToken = UserAccountAuthHelper.hasAuthToken(credentials: creds)
            let state = UserAccountAuthHelper.resolveAuthState(
                storedState: shared._authState.read(),
                hasCredentials: hasCreds
            )

            return CredentialSnapshot(
                hasCredentials: hasCreds,
                hasAuthToken: hasToken,
                authState: state,
                barcode: UserAccountAuthHelper.barcode(from: creds),
                pin: UserAccountAuthHelper.pin(from: creds)
            )
        }
    }

    // MARK: - Atomic Write

    func atomicUpdate(for libraryUUID: String?,
                      _ block: (TPPUserAccount) -> Void) {
        accountInfoQueue.sync(flags: .barrier) {
            if self.libraryUUID != libraryUUID {
                self.libraryUUID = libraryUUID
            }
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
