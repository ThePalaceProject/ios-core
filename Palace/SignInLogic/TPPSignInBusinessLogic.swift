//
//  TPPSignInBusinessLogic.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 5/5/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

@objc enum TPPAuthRequestType: Int {
  case signIn = 1
  case signOut = 2
}

@objc protocol TPPBookDownloadsDeleting {
  func reset(_ libraryID: String!)
}

extension TPPMyBooksDownloadCenter: TPPBookDownloadsDeleting {}

@objc protocol NYPLBookRegistrySyncing: NSObjectProtocol {
  var syncing: Bool {get}
  func reset(_ libraryAccountUUID: String)
  func syncResettingCache(_ resetCache: Bool,
                          completionHandler: ((_ errorDict: [AnyHashable: Any]?) -> Void)?)
  func save()
}

extension TPPBookRegistry: NYPLBookRegistrySyncing {}

@objc protocol TPPDRMAuthorizing: NSObjectProtocol {
  var workflowsInProgress: Bool {get}
  func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool
  func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: ((Bool, Error?, String?, String?) -> Void)!)
  func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: ((Bool, Error?) -> Void)!)
}

#if FEATURE_DRM_CONNECTOR
extension NYPLADEPT: TPPDRMAuthorizing {}
#endif

class TPPSignInBusinessLogic: NSObject, TPPSignedInStateProvider, TPPCurrentLibraryAccountProvider {
  /// Makes a business logic object with a network request executor that
  /// performs no persistent storage for caching.
  @objc convenience init(libraryAccountID: String,
                         libraryAccountsProvider: TPPLibraryAccountsProvider,
                         urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider,
                         bookRegistry: NYPLBookRegistrySyncing,
                         bookDownloadsCenter: TPPBookDownloadsDeleting,
                         userAccountProvider: TPPUserAccountProvider.Type,
                         uiDelegate: TPPSignInOutBusinessLogicUIDelegate?,
                         drmAuthorizer: TPPDRMAuthorizing?) {
    self.init(libraryAccountID: libraryAccountID,
              libraryAccountsProvider: libraryAccountsProvider,
              urlSettingsProvider: urlSettingsProvider,
              bookRegistry: bookRegistry,
              bookDownloadsCenter: bookDownloadsCenter,
              userAccountProvider: userAccountProvider,
              networkExecutor: TPPNetworkExecutor(credentialsProvider: uiDelegate,
                                                   cachingStrategy: .ephemeral,
                                                   delegateQueue: OperationQueue.main),
              uiDelegate: uiDelegate,
              drmAuthorizer: drmAuthorizer)
  }

  /// Designated initializer.
  init(libraryAccountID: String,
       libraryAccountsProvider: TPPLibraryAccountsProvider,
       urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider,
       bookRegistry: NYPLBookRegistrySyncing,
       bookDownloadsCenter: TPPBookDownloadsDeleting,
       userAccountProvider: TPPUserAccountProvider.Type,
       networkExecutor: TPPRequestExecuting,
       uiDelegate: TPPSignInOutBusinessLogicUIDelegate?,
       drmAuthorizer: TPPDRMAuthorizing?) {
    self.uiDelegate = uiDelegate
    self.libraryAccountID = libraryAccountID
    self.libraryAccountsProvider = libraryAccountsProvider
    self.urlSettingsProvider = urlSettingsProvider
    self.bookRegistry = bookRegistry
    self.bookDownloadsCenter = bookDownloadsCenter
    self.userAccountProvider = userAccountProvider
    self.networker = networkExecutor
    self.drmAuthorizer = drmAuthorizer
    self.samlHelper = TPPSAMLHelper()
    super.init()
    self.samlHelper.businessLogic = self
  }

  /// Lock for ensuring internal state consistency.
  let permissionsCheckLock = NSLock()

  /// Signing in and out may imply syncing the book registry.
  let bookRegistry: NYPLBookRegistrySyncing

  /// Signing out implies removing book downloads from the device.
  let bookDownloadsCenter: TPPBookDownloadsDeleting

  /// Provides the user account for a given library.
  private let userAccountProvider: TPPUserAccountProvider.Type

  /// THe object determining whether there's an ongoing DRM authorization.
  weak private(set) var drmAuthorizer: TPPDRMAuthorizing?

  /// The primary way for the business logic to communicate with the UI.
  @objc weak var uiDelegate: TPPSignInOutBusinessLogicUIDelegate?

  private var uiContext: String {
    return uiDelegate?.context ?? "Unknown"
  }

  /// This flag should be set if the instance is used to register new users.
  @objc var isLoggingInAfterSignUp: Bool = false

  /// A closure that will be invoked at the end of the sign-in process when
  /// refreshing authentication.
  var refreshAuthCompletion: (() -> Void)? = nil

  // MARK:- OAuth / SAML / Clever Info

  /// The current OAuth token if available.
  var authToken: String? = nil

  /// The current patron info if available.
  var patron: [String: Any]? = nil

  /// Settings used by OAuth sign-in flows.
  @objc let urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider

  /// Cookies used to authenticate. Only required for the SAML flow.
  @objc var cookies: [HTTPCookie]?

  /// Performs initiation rites for SAML sign-in.
  let samlHelper: TPPSAMLHelper

  /// This overrides the sign-in state logic to behave as if the user isn't
  /// authenticated. This is useful if we already have credentials, but
  /// the session expired (e.g. SAML flow).
  var ignoreSignedInState: Bool = false

  /// This is `true` during the process of validating credentials.
  ///
  /// Credentials validation happens *after* the initial sign-in intent
  /// where the app obtains the credentials in some way (e.g. user
  /// typing them in, or the redirection to 3rd party website for OAuth;
  /// see `logIn`), and *before* doing DRM authorization (see
  /// `drmAuthorizeUserData`).
  @objc var isValidatingCredentials = false

  // MARK:- Library Accounts Info

  /// The ID of the library this object is signing in to.
  /// - Note: This is also provided by `libraryAccountsProvider::currentAccount`
  /// but that could be returning nil if called too early on.
  @objc let libraryAccountID: String

  /// The object providing library account information.
  let libraryAccountsProvider: TPPLibraryAccountsProvider

  @objc var libraryAccount: Account? {
    return libraryAccountsProvider.account(libraryAccountID)
  }
  
  var currentAccount: Account? {
    return libraryAccount
  }

  @objc var selectedIDP: OPDS2SamlIDP?

  private var _selectedAuthentication: AccountDetails.Authentication?
  @objc var selectedAuthentication: AccountDetails.Authentication? {
    get {
      guard _selectedAuthentication == nil else { return _selectedAuthentication }
      guard userAccount.authDefinition == nil else { return userAccount.authDefinition }
      guard let auths = libraryAccount?.details?.auths else { return nil }
      guard auths.count > 1 else { return auths.first }

      return nil
    }
    set {
      _selectedAuthentication = newValue
    }
  }

  // MARK:- Network Requests Logic

  let networker: TPPRequestExecuting

  /// Creates a request object for signing in or out, depending on
  /// on which authentication mechanism is currently selected.
  /// - Note: If it was impossible to create the request, an error will be
  /// reported.
  /// - Parameters:
  ///   - authType: What kind of authentication request should be created.
  ///   - context: A string for further context for error reporting.
  /// - Returns: A request for signing in or signing out.
  func makeRequest(for authType: TPPAuthRequestType,
                   context: String) -> URLRequest? {

    let authTypeStr = (authType == .signOut ? "signing out" : "signing in")

    guard
      let urlStr = libraryAccount?.details?.userProfileUrl,
      let url = URL(string: urlStr) else {
        TPPErrorLogger.logError(
          withCode: .noURL,
          summary: "Error: unable to create URL for \(authTypeStr)",
          metadata: ["library.userProfileUrl": libraryAccount?.details?.userProfileUrl ?? "N/A"])
        return nil
    }

    var req = URLRequest(url: url)

    if let selectedAuth = selectedAuthentication,
      (selectedAuth.isOauth || selectedAuth.isSaml) {

      // The nil-coalescing on the authToken covers 2 cases:
      // - sign in, where uiDelegate has the token because we just obtained it
      // externally (via OAuth) but user account may not have been updated yet;
      // - sign out, where the uiDelegate may not have the token unless the user
      // just signed in, but the user account will definitely have it.
      if let authToken = (authToken ?? userAccount.authToken) {
        // Note: this is officially unsupported by the URL loading system
        // in iOS but it does work. It is necessary because the officially
        // supported method of providing authorization info to a request is via
        // `URLAuthenticationChallenge`, which has no api for Bearer token
        // authentication. Basic auth via username + password works fine with
        // challenges (see `NYPLSignInURLSessionChallengeHandler`).
        let authorization = "Bearer \(authToken)"
        req.addValue(authorization, forHTTPHeaderField: "Authorization")
      } else {
        Log.info(#file, "Auth token expected, but none is available.")
        TPPErrorLogger.logError(withCode: .validationWithoutAuthToken,
                                 summary: "Error \(authTypeStr): No token available during OAuth/SAML authentication validation",
                                 metadata: [
                                  "isSAML": selectedAuth.isSaml,
                                  "isOAuth": selectedAuth.isOauth,
                                  "context": context,
                                  "uiDelegate nil?": uiDelegate == nil ? "y" : "n"])
      }
    }

    return req
  }

  /// After having obtained the credentials for all authentication methods,
  /// including those that require negotiation with 3rd parties (such as
  /// Clever and SAML), validate said credentials against the Circulation
  /// Manager servers and call back to the UI once that's concluded.
  func validateCredentials() {
    isValidatingCredentials = true

    guard let req = makeRequest(for: .signIn, context: uiContext) else {
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.noURL.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey:
                              NSLocalizedString("Unable to contact the server because the URL for signing in is missing.",
                                                comment: "Error message for when the library profile url is missing from the authentication document the server provided."),
                            NSLocalizedRecoverySuggestionErrorKey:
                              NSLocalizedString("Try force-quitting the app and repeat the sign-in process.",
                                                comment: "Recovery instructions for when the URL to sign in is missing")])
      self.handleNetworkError(error, loggingContext: ["Context": uiContext])
      return
    }

    networker.executeRequest(req) { [weak self] result in
      guard let self = self else {
        return
      }

      self.isValidatingCredentials = false

      let loggingContext: [String: Any] = [
        "Request": req.loggableString,
        "Attempted Barcode": self.uiDelegate?.username?.md5hex() ?? "N/A",
        "Context": self.uiContext]

      switch result {
      case .success(let responseData, _):
        #if FEATURE_DRM_CONNECTOR
        if (AdobeCertificate.defaultCertificate?.hasExpired == true) {
          self.finalizeSignIn(forDRMAuthorization: true)
        } else {
          self.drmAuthorizeUserData(responseData, loggingContext: loggingContext)
        }
        #else
        self.finalizeSignIn(forDRMAuthorization: true)
        #endif

      case .failure(let errorWithProblemDoc, let response):
        self.handleNetworkError(errorWithProblemDoc as NSError,
                                response: response,
                                loggingContext: loggingContext)
      }
    }
  }

  /// Uses the problem document's `title` and `message` fields to
  ///  communicate a user friendly error info to the `uiDelegate`.
  /// Also logs the `error`.
  private func handleNetworkError(_ error: NSError,
                                  response: URLResponse? = nil,
                                  loggingContext: [String: Any]) {
    let problemDoc = error.problemDocument

    // TPPNetworkExecutor already logged the error, but this is more
    // informative
    TPPErrorLogger.logLoginError(error,
                                  library: libraryAccount,
                                  response: response,
                                  problemDocument: problemDoc,
                                  metadata: loggingContext)

    let title, message: String?
    if let problemDoc = problemDoc {
      title = problemDoc.title
      message = problemDoc.detail
    } else {
      title = "SettingsAccountViewControllerLoginFailed"
      message = nil
    }

    TPPMainThreadRun.asyncIfNeeded {
      self.uiDelegate?.businessLogic(self,
                                     didEncounterValidationError: error,
                                     userFriendlyErrorTitle: title,
                                     andMessage: message)
    }
  }

  /// Initiates process of signing in with the server.
  @objc func logIn() {
    NotificationCenter.default.post(name: .TPPIsSigningIn, object: true)

    TPPMainThreadRun.asyncIfNeeded {
      self.uiDelegate?.businessLogicWillSignIn(self)
    }

    if selectedAuthentication?.isOauth ?? false {
      oauthLogIn()
    } else if selectedAuthentication?.isSaml ?? false {
      samlHelper.logIn()
    } else {
      validateCredentials()
    }
  }

  @objc var isAuthenticationDocumentLoading: Bool = false

  /// Makes sure we have the `libraryAccount` `details` loading the
  /// authentication document if needed.
  /// - Note: if an error occurs while loading the authentication document,
  /// an error is reported via `TPPErrorLogger`.
  /// - Parameter completion: Always called once we have the library details.
  @objc func ensureAuthenticationDocumentIsLoaded(_ completion: @escaping (Bool) -> Void) {
    if libraryAccount?.details != nil {
      completion(true)
      return
    }

    isAuthenticationDocumentLoading = true
    libraryAccount?.loadAuthenticationDocument(using: self) { success in
      self.isAuthenticationDocumentLoading = false
      completion(success)
    }
  }

  /// Set up the sign-in business logic to refresh the authentication token
  /// for the currently signed in user.
  ///
  /// This method determines if user input is required in order to keep the
  /// user login session going. If no user input is required, it proceeds
  /// to fetch a new token keeping the user logged in.
  ///
  /// - IMPORTANT: This method is not thread-safe.
  /// - Parameters:
  ///   - usingExistingCredentials: Force using existing credentials for the
  ///   authentication refresh attempt.
  ///   - completion: Block to be run after the authentication refresh attempt
  ///   is performed.
  /// - Returns: `true` if a sign-in UI is needed to refresh authentication.
  @objc func refreshAuthIfNeeded(usingExistingCredentials: Bool,
                                 completion: (() -> Void)?) -> Bool {

    guard
      let authDef = userAccount.authDefinition,
      (authDef.isBasic || authDef.isOauth || authDef.isSaml)
    else {
      completion?()
      return false
    }

    refreshAuthCompletion = completion

    // reset authentication if needed
    if authDef.isSaml || authDef.isOauth {
      if !usingExistingCredentials {
        // if current authentication is SAML and we don't want to use current
        // credentials, we need to force log in process. this is for the case
        // when we were logged in, but IDP expired our session and if this
        // happens, we want the user to pick the idp to begin reauthentication
        ignoreSignedInState = true
        if authDef.isSaml {
          selectedAuthentication = nil
        }
      }
    }

    // set up UI and log in if needed
    if authDef.isBasic {
      if usingExistingCredentials && userAccount.hasBarcodeAndPIN() {
        if uiDelegate == nil {
          #if DEBUG
          preconditionFailure("uiDelegate must be set for logIn to work correctly")
          #else
          TPPErrorLogger.logError(
            withCode: .appLogicInconsistency,
            summary: "uiDelegate missing while refreshing basic auth",
            metadata: [
              "usingExistingCredentials": usingExistingCredentials,
              "hashedBarcode": userAccount.barcode?.md5hex() ?? "N/A"
          ])
          #endif
        }
        uiDelegate?.usernameTextField?.text = userAccount.barcode
        uiDelegate?.PINTextField?.text = userAccount.PIN

        logIn()
        return false
      } else {
        uiDelegate?.usernameTextField?.text = ""
        uiDelegate?.PINTextField?.text = ""
        uiDelegate?.usernameTextField?.becomeFirstResponder()
      }
    }

    return true
  }

  // MARK:- User Account Management

  /// The user account for the library we are signing in to.
  @objc var userAccount: TPPUserAccount {
    return userAccountProvider.sharedAccount(libraryUUID: libraryAccountID)
  }

  /// Updates the user account for the library we are signing in to.
  /// - Parameters:
  ///   - drmSuccess: whether the DRM authorization was successful or not.
  ///   Ignored if the app is built without DRM support.
  ///   - barcode: The new barcode, if available.
  ///   - pin: The new PIN, if barcode is provided.
  ///   - authToken: the token if `selectedAuthentication` is OAuth or SAML. 
  ///   - patron: The patron info for OAuth / SAML authentication.
  ///   - cookies: Cookies for SAML authentication.
  func updateUserAccount(forDRMAuthorization drmSuccess: Bool,
                         withBarcode barcode: String?,
                         pin: String?,
                         authToken: String?,
                         patron: [String:Any]?,
                         cookies: [HTTPCookie]?) {
    #if FEATURE_DRM_CONNECTOR
    guard drmSuccess else {
      userAccount.removeAll()
      return
    }
    #endif

    if let selectedAuthentication = selectedAuthentication {
      if selectedAuthentication.isOauth || selectedAuthentication.isSaml {
        if let authToken = authToken {
          userAccount.setAuthToken(authToken)
        }
        if let patron = patron {
          userAccount.setPatron(patron)
        }
      } else {
        setBarcode(barcode, pin: pin)
      }

      if selectedAuthentication.isSaml {
        if let cookies = cookies {
          userAccount.setCookies(cookies)
        }
      }
    } else {
      setBarcode(barcode, pin: pin)
    }

    userAccount.authDefinition = selectedAuthentication

    if libraryAccountID == libraryAccountsProvider.currentAccountId {
      bookRegistry.syncResettingCache(false) { [weak bookRegistry] errorDict in
        if errorDict == nil {
          bookRegistry?.save()
        }
      }
    }

    NotificationCenter.default.post(name: .TPPIsSigningIn, object: false)
  }

  private func setBarcode(_ barcode: String?, pin: String?) {
    if let barcode = barcode, let pin = pin {
      userAccount.setBarcode(barcode, PIN:pin)
    }
  }

  // MARK: - Available Features Checks

  @objc func librarySupportsBarcodeDisplay() -> Bool {
    // For now, only supports libraries granted access in Accounts.json,
    // is signed in, and has an authorization ID returned from the loans feed.
    return userAccount.hasBarcodeAndPIN() &&
      userAccount.authorizationIdentifier != nil &&
      (selectedAuthentication?.supportsBarcodeDisplay ?? false)
  }

  func isSignedIn() -> Bool {
    if ignoreSignedInState {
      return false
    }
    return userAccount.hasCredentials()
  }

  @objc func isSamlPossible() -> Bool {
    libraryAccount?.details?.auths.contains { $0.isSaml } ?? false
  }

  @objc func shouldShowEULALink() -> Bool {
    return libraryAccount?.details?.getLicenseURL(.eula) != nil
  }
}
