//
//  AccountDetailViewModel.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import LocalAuthentication

@MainActor
class AccountDetailViewModel: NSObject, ObservableObject {
  
  // MARK: - Published Properties
  @Published var usernameText: String = ""
  @Published var pinText: String = ""
  @Published var isLoading: Bool = false
  @Published var isLoadingAuth: Bool = false
  @Published var isPINHidden: Bool = true
  @Published var isSyncEnabled: Bool = false
  @Published var showAgeVerification: Bool = false
  @Published var errorMessage: String?
  @Published var showingAlert: Bool = false
  @Published var alertTitle: String = ""
  @Published var alertMessage: String = ""
  @Published var tableData: [[CellType]] = []
  @Published var barcodeImage: UIImage?
  @Published var showBarcode: Bool = false
  
  // MARK: - Properties
  var businessLogic: TPPSignInBusinessLogic
  var frontEndValidator: TPPUserAccountFrontEndValidation?
  private let libraryAccountID: String
  private var cancellables = Set<AnyCancellable>()
  var forceEditability: Bool = false
  
  // MARK: - Computed Properties
  var selectedAccount: Account? {
    businessLogic.libraryAccount
  }
  
  var selectedUserAccount: TPPUserAccount {
    businessLogic.userAccount
  }
  
  var isSignedIn: Bool {
    selectedUserAccount.hasCredentials()
  }
  
  var canSignIn: Bool {
    let oauthLogin = businessLogic.selectedAuthentication?.isOauth ?? false
    let samlLogin = businessLogic.selectedAuthentication?.isSaml ?? false
    
    // OAuth and SAML don't require local credentials
    if oauthLogin || samlLogin {
      return true
    }
    
    // For basic auth, check if credentials are filled
    let barcodeHasText = !usernameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let pinHasText = !pinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let pinIsNotRequired = businessLogic.selectedAuthentication?.pinKeyboard == .none
    
    return (barcodeHasText && pinHasText) || (barcodeHasText && pinIsNotRequired)
  }
  
  var libraryName: String {
    selectedAccount?.name ?? ""
  }
  
  var libraryLogo: UIImage? {
    selectedAccount?.logo
  }
  
  var signInMessage: String {
    String(format: NSLocalizedString("To download books, please sign in to %@.", comment: "Sign in prompt"), libraryName)
  }
  
  // MARK: - Initialization
  init(libraryAccountID: String) {
    self.libraryAccountID = libraryAccountID
    
    // Temporary placeholder - will be set after super.init()
    self.businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: libraryAccountID,
      libraryAccountsProvider: AccountsManager.shared,
      urlSettingsProvider: TPPSettings.shared,
      bookRegistry: TPPBookRegistry.shared,
      bookDownloadsCenter: MyBooksDownloadCenter.shared,
      userAccountProvider: TPPUserAccount.self,
      uiDelegate: nil,
      drmAuthorizer: nil
    )
    
    super.init()
    
    // Now properly initialize with self as delegate
    var drmAuthorizer: TPPDRMAuthorizing?
#if FEATURE_DRM_CONNECTOR
    if AdobeCertificate.defaultCertificate?.hasExpired == false {
      drmAuthorizer = NYPLADEPT.sharedInstance()
    }
#endif
    
    // Create proper network executor with credentials provider
    let networkExecutor = TPPNetworkExecutor(
      credentialsProvider: self,
      cachingStrategy: .ephemeral,
      delegateQueue: OperationQueue.main
    )
    
    // Recreate business logic with proper configuration
    self.businessLogic = TPPSignInBusinessLogic(
      libraryAccountID: libraryAccountID,
      libraryAccountsProvider: AccountsManager.shared,
      urlSettingsProvider: TPPSettings.shared,
      bookRegistry: TPPBookRegistry.shared,
      bookDownloadsCenter: MyBooksDownloadCenter.shared,
      userAccountProvider: TPPUserAccount.self,
      networkExecutor: networkExecutor,
      uiDelegate: self,
      drmAuthorizer: drmAuthorizer
    )
    
    self.frontEndValidator = TPPUserAccountFrontEndValidation(
      account: selectedAccount!,
      businessLogic: businessLogic,
      inputProvider: self
    )
    
    setupObservers()
    loadInitialData()
  }
  
  // MARK: - Setup
  private func setupObservers() {
    NotificationCenter.default.publisher(for: .TPPUserAccountDidChange)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.accountDidChange()
        }
      }
      .store(in: &cancellables)
  }
  
  private func loadInitialData() {
    Log.info(#file, "Loading initial data...")
    isLoadingAuth = true
    
    if businessLogic.libraryAccount?.details != nil {
      Log.info(#file, "Library account details already loaded")
      Task { @MainActor in
        setupViews()
        accountDidChange()
        isLoadingAuth = false
        Log.info(#file, "Initial setup complete")
      }
    } else {
      Log.info(#file, "Loading authentication document...")
      businessLogic.ensureAuthenticationDocumentIsLoaded { [weak self] success in
        Task { @MainActor in
          guard let self = self else { return }
          
          Log.info(#file, "Authentication document loaded: \(success)")
          self.isLoadingAuth = false
          
          if success {
            self.setupViews()
            self.accountDidChange()
            Log.info(#file, "Initial setup complete after auth doc load")
          } else {
            Log.error(#file, "Failed to load authentication document")
            self.showError(
              title: Strings.Error.connectionFailed,
              message: NSLocalizedString("Please check your connection and try again.", comment: "Connection error")
            )
          }
        }
      }
    }
  }
  
  private func setupViews() {
    isSyncEnabled = selectedAccount?.details?.syncPermissionGranted ?? false
    setupTableData()
    loadBarcodeIfNeeded()
  }
  
  private func loadBarcodeIfNeeded() {
    guard businessLogic.librarySupportsBarcodeDisplay(),
          isSignedIn,
          let libraryName = selectedAccount?.name,
          let identifier = selectedUserAccount.authorizationIdentifier else {
      barcodeImage = nil
      return
    }
    
    let barcode = TPPBarcode(library: libraryName)
    barcodeImage = barcode.image(fromString: identifier)
  }
  
  // MARK: - Table Data Setup
  private func setupTableData() {
    Log.debug(#file, "Setting up table data...")
    let section0 = accountInfoSection()
    var sections: [[CellType]] = [section0]
    
    if businessLogic.shouldShowSyncButton() {
      sections.append([.syncButton])
    }
    
    if businessLogic.registrationIsPossible() {
      sections.insert([.registration], at: 1)
    }
    
    var aboutSection: [CellType] = []
    if selectedAccount?.details?.getLicenseURL(.privacyPolicy) != nil {
      aboutSection.append(.privacyPolicy)
    }
    if selectedAccount?.details?.getLicenseURL(.contentLicenses) != nil {
      aboutSection.append(.contentLicense)
    }
    if businessLogic.shouldShowSyncButton() {
      aboutSection.append(.advancedSettings)
    }
    
    if selectedAccount?.hasSupportOption == true {
      sections.append([.reportIssue])
    }
    
    if !aboutSection.isEmpty {
      sections.append(aboutSection)
    }
    
    tableData = sections.filter { !$0.isEmpty }
    Log.debug(#file, "Table data setup complete: \(sections.count) sections")
  }
  
  private func accountInfoSection() -> [CellType] {
    var workingSection: [CellType] = []
    
    Log.debug(#file, "Building account info section - needsAgeCheck: \(businessLogic.selectedAuthentication?.needsAgeCheck ?? false), needsAuth: \(businessLogic.selectedAuthentication?.needsAuth ?? false), isSignedIn: \(isSignedIn)")
    
    if businessLogic.selectedAuthentication?.needsAgeCheck == true {
      workingSection = [.ageCheck]
    } else if businessLogic.selectedAuthentication?.needsAuth == false {
      // No authentication needed
    } else if businessLogic.selectedAuthentication != nil && isSignedIn {
      workingSection = cellsForAuthMethod(businessLogic.selectedAuthentication!)
    } else if !isSignedIn && selectedUserAccount.needsAuth {
      if businessLogic.isSamlPossible() {
        let info = String(format: NSLocalizedString("Log in to %@ required to download books.", comment: ""), libraryName)
        workingSection.append(.infoHeader(info))
      }
      
      if let details = businessLogic.libraryAccount?.details,
         details.auths.count > 1,
         details.defaultAuth?.isToken == false {
        for auth in details.auths {
          workingSection.append(.authMethod(auth))
          if auth.methodDescription == businessLogic.selectedAuthentication?.methodDescription {
            workingSection.append(contentsOf: cellsForAuthMethod(auth))
          }
        }
      } else if let firstAuth = businessLogic.libraryAccount?.details?.auths.first {
        workingSection.append(contentsOf: cellsForAuthMethod(firstAuth))
      } else if let selectedAuth = businessLogic.selectedAuthentication {
        workingSection.append(contentsOf: cellsForAuthMethod(selectedAuth))
      }
      
      if businessLogic.canResetPassword {
        workingSection.append(.passwordReset)
      }
    } else if let selectedAuth = businessLogic.selectedAuthentication {
      workingSection.append(contentsOf: cellsForAuthMethod(selectedAuth))
    }
    
    if businessLogic.librarySupportsBarcodeDisplay() {
      workingSection.insert(.barcodeImage, at: 0)
    }
    
    return workingSection
  }
  
  private func cellsForAuthMethod(_ auth: AccountDetails.Authentication) -> [CellType] {
    if auth.isOauth {
      return [.logInSignOut]
    } else if auth.isSaml && isSignedIn {
      return [.logInSignOut]
    } else if auth.isSaml {
      return (auth.samlIdps ?? []).map { idp in CellType.samlIDP(idp) }
    } else if auth.pinKeyboard != .none {
      return [.barcode, .pin, .logInSignOut]
    } else {
      pinText = ""
      return [.barcode, .logInSignOut]
    }
  }
  
  // MARK: - Actions
  func signIn() {
    Log.info(#file, "Sign in button tapped")
    
    if isSignedIn {
      Log.debug(#file, "User is signed in, showing sign out alert")
      presentSignOutAlert()
      return
    }
    
    // For OAuth, we can proceed directly
    if businessLogic.selectedAuthentication?.isOauth == true {
      Log.info(#file, "Starting OAuth sign-in")
      businessLogic.logIn()
      return
    }
    
    // For basic auth, check if fields are filled
    guard canSignIn else {
      Log.debug(#file, "Cannot sign in: credentials not filled")
      return
    }
    
    // Sign in with token or basic auth
    if let tokenURL = selectedUserAccount.authDefinition?.tokenURL {
      Log.info(#file, "Starting token-based sign-in")
      businessLogic.logIn(with: tokenURL)
    } else {
      Log.info(#file, "Starting basic auth sign-in")
      businessLogic.logIn()
    }
  }
  
  func signOut() {
    if let alert = businessLogic.logOutOrWarn() {
      // Present alert through UIKit bridge
      TPPPresentationUtils.safelyPresent(alert, animated: true)
    }
  }
  
  private func presentSignOutAlert() {
    let logoutString: String
    if businessLogic.shouldShowSyncButton() && !isSyncEnabled {
      logoutString = NSLocalizedString("If you sign out without enabling Sync, your books and any saved bookmarks will be removed.", comment: "")
    } else {
      logoutString = NSLocalizedString("If you sign out, your books and any saved bookmarks will be removed.", comment: "")
    }
    
    let alert = UIAlertController(
      title: NSLocalizedString("Sign out", comment: ""),
      message: logoutString,
      preferredStyle: .alert
    )
    
    alert.addAction(UIAlertAction(
      title: NSLocalizedString("Sign out", comment: ""),
      style: .destructive,
      handler: { [weak self] _ in
        self?.signOut()
      }
    ))
    
    alert.addAction(UIAlertAction(
      title: Strings.Generic.cancel,
      style: .cancel
    ))
    
    TPPPresentationUtils.safelyPresent(alert, animated: true)
  }
  
  func togglePINVisibility() {
    if !pinText.isEmpty && isPINHidden {
      let context = LAContext()
      if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
        context.evaluatePolicy(
          .deviceOwnerAuthentication,
          localizedReason: NSLocalizedString("Authenticate to reveal your PIN.", comment: "")
        ) { [weak self] success, error in
          Task { @MainActor in
            if success {
              self?.isPINHidden.toggle()
            } else if let error = error {
              TPPErrorLogger.logError(error, summary: "Error while trying to show/hide the PIN", metadata: nil)
            }
          }
        }
      } else {
        isPINHidden.toggle()
      }
    } else {
      isPINHidden.toggle()
    }
  }
  
  func toggleSync() {
    isSyncEnabled.toggle()
    selectedAccount?.details?.syncPermissionGranted = isSyncEnabled
  }
  
  func scanBarcode() {
    #if !OPENEBOOKS
    TPPBarcode.presentScanner { [weak self] resultString in
      Task { @MainActor in
        if let resultString = resultString {
          self?.usernameText = resultString
        }
      }
    }
    #endif
  }
  
  func resetPassword() {
    businessLogic.resetPassword()
  }
  
  func performAgeCheck() {
    guard let account = selectedAccount else { return }
    
    AccountsManager.shared.ageCheck.verifyCurrentAccountAgeRequirement(
      userAccountProvider: selectedUserAccount,
      currentLibraryAccountProvider: businessLogic
    ) { [weak self] aboveAgeLimit in
      Task { @MainActor in
        account.details?.userAboveAgeLimit = aboveAgeLimit
        if !aboveAgeLimit {
          MyBooksDownloadCenter.shared.reset(account.uuid)
          TPPBookRegistry.shared.reset(account.uuid)
        }
        self?.setupTableData()
        NotificationCenter.default.post(name: .TPPCurrentAccountDidChange, object: nil)
      }
    }
  }
  
  func selectAuthMethod(_ auth: AccountDetails.Authentication) {
    businessLogic.selectedIDP = nil
    businessLogic.selectedAuthentication = auth
    setupTableData()
  }
  
  func selectSAMLIDP(_ idp: OPDS2SamlIDP) {
    Log.info(#file, "SAML IDP selected: \(idp.displayName ?? "unknown")")
    businessLogic.selectedIDP = idp
    businessLogic.logIn()
  }
  
  func openRegistration() {
    businessLogic.startRegularCardCreation { [weak self] navVC, error in
      Task { @MainActor in
        if let error = error {
          self?.showError(
            title: Strings.Generic.error,
            message: error.localizedDescription
          )
          return
        }
        
        if let navVC = navVC {
          navVC.navigationBar.topItem?.leftBarButtonItem = UIBarButtonItem(
            title: Strings.Generic.back,
            style: .plain,
            target: self,
            action: #selector(self?.dismissRegistration)
          )
          navVC.modalPresentationStyle = .formSheet
          TPPPresentationUtils.safelyPresent(navVC, animated: true)
        }
      }
    }
  }
  
  @objc private func dismissRegistration() {
    if let presented = UIApplication.shared.windows.first?.rootViewController?.presentedViewController {
      presented.dismiss(animated: true)
    }
  }
  
  private func accountDidChange() {
    if isSignedIn {
      usernameText = selectedUserAccount.barcode ?? ""
      pinText = selectedUserAccount.pin ?? ""
    } else {
      usernameText = ""
      pinText = ""
    }
    
    setupTableData()
    loadBarcodeIfNeeded()
  }
  
  private func showError(title: String, message: String) {
    alertTitle = title
    alertMessage = message
    showingAlert = true
  }
}

// MARK: - CellType Enum
enum CellType: Hashable {
  case advancedSettings
  case ageCheck
  case barcodeImage
  case barcode
  case pin
  case logInSignOut
  case registration
  case syncButton
  case about
  case privacyPolicy
  case contentLicense
  case reportIssue
  case passwordReset
  case authMethod(AccountDetails.Authentication)
  case samlIDP(OPDS2SamlIDP)
  case infoHeader(String)
  
  func hash(into hasher: inout Hasher) {
    switch self {
    case .advancedSettings:
      hasher.combine("advancedSettings")
    case .ageCheck:
      hasher.combine("ageCheck")
    case .barcodeImage:
      hasher.combine("barcodeImage")
    case .barcode:
      hasher.combine("barcode")
    case .pin:
      hasher.combine("pin")
    case .logInSignOut:
      hasher.combine("logInSignOut")
    case .registration:
      hasher.combine("registration")
    case .syncButton:
      hasher.combine("syncButton")
    case .about:
      hasher.combine("about")
    case .privacyPolicy:
      hasher.combine("privacyPolicy")
    case .contentLicense:
      hasher.combine("contentLicense")
    case .reportIssue:
      hasher.combine("reportIssue")
    case .passwordReset:
      hasher.combine("passwordReset")
    case .authMethod(let auth):
      hasher.combine("authMethod-\(auth.methodDescription ?? "")")
    case .samlIDP(let idp):
      hasher.combine("samlIDP-\(idp.displayName ?? "")")
    case .infoHeader(let text):
      hasher.combine("infoHeader-\(text)")
    }
  }
  
  static func == (lhs: CellType, rhs: CellType) -> Bool {
    switch (lhs, rhs) {
    case (.advancedSettings, .advancedSettings),
         (.ageCheck, .ageCheck),
         (.barcodeImage, .barcodeImage),
         (.barcode, .barcode),
         (.pin, .pin),
         (.logInSignOut, .logInSignOut),
         (.registration, .registration),
         (.syncButton, .syncButton),
         (.about, .about),
         (.privacyPolicy, .privacyPolicy),
         (.contentLicense, .contentLicense),
         (.reportIssue, .reportIssue),
         (.passwordReset, .passwordReset):
      return true
    case (.authMethod(let auth1), .authMethod(let auth2)):
      return auth1.methodDescription == auth2.methodDescription
    case (.samlIDP(let idp1), .samlIDP(let idp2)):
      return idp1.displayName == idp2.displayName
    case (.infoHeader(let text1), .infoHeader(let text2)):
      return text1 == text2
    default:
      return false
    }
  }
}

// MARK: - NYPLUserAccountInputProvider
extension AccountDetailViewModel: NYPLUserAccountInputProvider {
  var usernameTextField: UITextField? {
    get { nil }
    set { }
  }
  
  var PINTextField: UITextField? {
    get { nil }
    set { }
  }
}

// MARK: - TPPSignInOutBusinessLogicUIDelegate
extension AccountDetailViewModel: TPPSignInOutBusinessLogicUIDelegate {
  var context: String {
    "Settings Tab"
  }
  
  func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    Log.info(#file, "Business logic will sign in")
    isLoading = true
    
    // Safety timeout: clear loading state after 30 seconds if no response
    Task {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      if self.isLoading {
        Log.warn(#file, "Sign-in timeout reached, clearing loading state")
        await MainActor.run {
          self.isLoading = false
        }
      }
    }
  }
  
  func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    Log.info(#file, "Business logic cancelled sign in")
    isLoading = false
  }
  
  func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    Log.info(#file, "Business logic completed sign in")
    isLoading = false
    accountDidChange()
  }
  
  func businessLogic(_ logic: TPPSignInBusinessLogic, didEncounterValidationError error: Error?, userFriendlyErrorTitle title: String?, andMessage message: String?) {
    Log.error(#file, "Validation error encountered: \(error?.localizedDescription ?? "unknown")")
    isLoading = false
    
    if let error = error as? NSError, error.code == NSURLErrorCancelled {
      pinText = ""
    }
    
    let errorTitle = title ?? Strings.Error.loginErrorTitle
    let errorMessage = message ?? (error?.localizedDescription ?? Strings.Error.unknownRequestError)
    showError(title: errorTitle, message: errorMessage)
  }
  
  func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {
    Log.info(#file, "Business logic will sign out")
    isLoading = true
  }
  
  func businessLogic(_ logic: TPPSignInBusinessLogic, didEncounterSignOutError error: Error?, withHTTPStatusCode httpStatusCode: Int) {
    Log.error(#file, "Sign out error: \(error?.localizedDescription ?? "unknown"), status: \(httpStatusCode)")
    isLoading = false
    
    let title: String
    let message: String
    
    if httpStatusCode == 401 {
      title = "Unexpected Credentials"
      message = "Your username or password may have changed since the last time you logged in.\n\nIf you believe this is an error, please contact your library."
    } else if let error = error {
      title = "SettingsAccountViewControllerLogoutFailed"
      message = error.localizedDescription
    } else {
      title = "SettingsAccountViewControllerLogoutFailed"
      message = NSLocalizedString("An unknown error occurred while trying to sign out.", comment: "")
    }
    
    showError(title: NSLocalizedString(title, comment: ""), message: NSLocalizedString(message, comment: ""))
  }
  
  func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {
    Log.info(#file, "Business logic finished deauthorizing")
    isLoading = false
    setupTableData()
    accountDidChange()
  }
  
  func dismiss(animated flag: Bool, completion: (() -> Void)?) {
    if let presented = UIApplication.shared.windows.first?.rootViewController?.presentedViewController {
      presented.dismiss(animated: flag, completion: completion)
    }
  }
  
  func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)?) {
    TPPPresentationUtils.safelyPresent(viewControllerToPresent, animated: flag, completion: completion)
  }
}

// MARK: - NYPLBasicAuthCredentialsProvider
extension AccountDetailViewModel: NYPLBasicAuthCredentialsProvider {
  var username: String? {
    self.usernameText.isEmpty ? nil : self.usernameText
  }
  
  var pin: String? {
    self.pinText.isEmpty ? nil : self.pinText
  }
}

