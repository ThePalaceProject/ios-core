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
  typealias DisplayStrings = Strings.Settings
  
  // MARK: - Constants
  
  private enum Constants {
    static let signInTimeoutSeconds: UInt64 = 30_000_000_000
    static let maxUsernameLength = 25
  }
  
  // MARK: - Published Properties
  
  @Published var usernameText = ""
  @Published var pinText = ""
  @Published var isLoading = false
  @Published var isLoadingAuth = false
  @Published var isPINHidden = true
  @Published var isSyncEnabled = false
  @Published var showAgeVerification = false
  @Published var errorMessage: String?
  @Published var showingAlert = false
  @Published var alertTitle = ""
  @Published var alertMessage = ""
  @Published var tableData: [[CellType]] = []
  @Published var barcodeImage: UIImage?
  @Published var showBarcode = false
  @Published var isSigningOut = false
  
  // MARK: - Properties
  
  var businessLogic: TPPSignInBusinessLogic
  var frontEndValidator: TPPUserAccountFrontEndValidation?
  private let libraryAccountID: String
  private var cancellables = Set<AnyCancellable>()
  var forceEditability = false
  
  // MARK: - Computed Properties
  
  var selectedAccount: Account? {
    businessLogic.libraryAccount
  }
  
  var selectedUserAccount: TPPUserAccount {
    businessLogic.userAccount
  }
  
  @Published var isSignedIn: Bool = false
  
  var canSignIn: Bool {
    if businessLogic.selectedAuthentication?.isOauth == true ||
       businessLogic.selectedAuthentication?.isSaml == true {
      return true
    }
    
    let barcodeHasText = !usernameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let pinHasText = !pinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    
    let pinIsNotRequired = businessLogic.selectedAuthentication.map { $0.pinKeyboard == .none } ?? true
    
    let result = (barcodeHasText && pinHasText) || (barcodeHasText && pinIsNotRequired)
    
    return result
  }
  
  var libraryName: String {
    selectedAccount?.name ?? ""
  }
  
  var libraryLogo: UIImage? {
    selectedAccount?.logo
  }
  
  // MARK: - Initialization
  
  init(libraryAccountID: String) {
    self.libraryAccountID = libraryAccountID
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
    
    // Initialize isSignedIn based on current credentials AND auth state
    let account = TPPUserAccount.sharedAccount(libraryUUID: libraryAccountID)
    self.isSignedIn = account.hasCredentials() && account.authState == .loggedIn
    
    super.init()
    
    var drmAuthorizer: TPPDRMAuthorizing?
    #if FEATURE_DRM_CONNECTOR
    // Use safe DRM container to prevent EXC_BREAKPOINT crashes during initialization
    if AdobeCertificate.isDRMAvailable {
      drmAuthorizer = AdobeDRMService.shared.adeptInstance
    }
    #endif
    
    let networkExecutor = TPPNetworkExecutor(
      credentialsProvider: self,
      cachingStrategy: .ephemeral,
      delegateQueue: OperationQueue.main
    )
    
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
    
    if let account = selectedAccount {
      frontEndValidator = TPPUserAccountFrontEndValidation(
        account: account,
        businessLogic: businessLogic,
        inputProvider: self
      )
    }
    
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
    
    // Listen for account switches to refresh sign-in state
    NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.accountDidChange()
        }
      }
      .store(in: &cancellables)
  }
  
  private func loadInitialData() {
    isLoadingAuth = true
    
    if businessLogic.libraryAccount?.details != nil {
      Task { @MainActor in
        setupViews()
        accountDidChange()
        isLoadingAuth = false
      }
    } else {
      businessLogic.ensureAuthenticationDocumentIsLoaded { [weak self] success in
        Task { @MainActor in
          guard let self else { return }
          self.isLoadingAuth = false
          
          if success {
            self.setupViews()
            self.accountDidChange()
          } else {
            self.showError(
              title: Strings.Error.connectionFailed,
              message: NSLocalizedString("Please check your connection and try again.", comment: "")
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
  }
  
  private func accountInfoSection() -> [CellType] {
    var workingSection: [CellType] = []
    
    if businessLogic.selectedAuthentication?.needsAgeCheck == true {
      return [.ageCheck]
    }
    
    guard businessLogic.selectedAuthentication?.needsAuth != false else {
      return []
    }
    
    if let selectedAuth = businessLogic.selectedAuthentication, isSignedIn {
      workingSection = cellsForAuthMethod(selectedAuth)
    } else if !isSignedIn && selectedUserAccount.needsAuth {
      if businessLogic.isSamlPossible() {
        workingSection.append(.infoHeader(Strings.AccountDetail.signInMessage(libraryName: libraryName)))
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
    }
    
    if auth.isSaml && isSignedIn {
      return [.logInSignOut]
    }
    
    if auth.isSaml {
      return (auth.samlIdps ?? []).map { CellType.samlIDP($0) }
    }
    
    if auth.pinKeyboard != .none {
      return [.barcode, .pin, .logInSignOut]
    }
    
    return [.barcode, .logInSignOut]
  }
  
  // MARK: - Actions
  
  func signIn() {
    guard !isSignedIn else {
      isSigningOut = true
      presentSignOutAlert()
      return
    }
    
    isSigningOut = false
    
    if businessLogic.selectedAuthentication?.isOauth == true {
      businessLogic.logIn()
      return
    }
    
    guard canSignIn else { return }
    
    if let tokenURL = selectedUserAccount.authDefinition?.tokenURL {
      businessLogic.logIn(with: tokenURL)
    } else {
      businessLogic.logIn()
    }
  }
  
  func signOut() {
    isSigningOut = true
    guard let alert = businessLogic.logOutOrWarn() else { return }
    TPPPresentationUtils.safelyPresent(alert, animated: true)
  }
  
  private func presentSignOutAlert() {
    let message = Strings.AccountDetail.signOutWarningWithSync(syncEnabled: isSyncEnabled)
    
    let alert = UIAlertController(
      title: DisplayStrings.signOut,
      message: message,
      preferredStyle: .alert
    )
    
    alert.addAction(UIAlertAction(
      title: DisplayStrings.signOut,
      style: .destructive,
      handler: { [weak self] _ in self?.signOut() }
    ))
    
    alert.addAction(UIAlertAction(
      title: Strings.Generic.cancel,
      style: .cancel
    ))
    
    TPPPresentationUtils.safelyPresent(alert, animated: true)
  }
  
  func togglePINVisibility() {
    guard !pinText.isEmpty && isPINHidden else {
      isPINHidden.toggle()
      return
    }
    
    let context = LAContext()
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
      isPINHidden.toggle()
      return
    }
    
    context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: DisplayStrings.authenticateToRevealPIN
    ) { [weak self] success, error in
      Task { @MainActor in
        if success {
          self?.isPINHidden.toggle()
        } else if let error {
          TPPErrorLogger.logError(error, summary: "Error while trying to show/hide the PIN", metadata: nil)
        }
      }
    }
  }
  
  func updateSync(enabled: Bool) {
    selectedAccount?.details?.syncPermissionGranted = enabled
  }
  
  func scanBarcode() {
    #if !OPENEBOOKS
    TPPBarcode.presentScanner { [weak self] resultString in
      Task { @MainActor in
        self?.usernameText = resultString ?? ""
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
    businessLogic.selectedIDP = idp
    businessLogic.logIn()
  }
  
  func openRegistration() {
    businessLogic.startRegularCardCreation { [weak self] navVC, error in
      Task { @MainActor in
        if let error {
          self?.showError(
            title: Strings.Generic.error,
            message: error.localizedDescription
          )
          return
        }
        
        guard let navVC else { return }
        
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
  
  @objc private func dismissRegistration() {
    guard let presented = UIApplication.shared.windows.first?.rootViewController?.presentedViewController else {
      return
    }
    presented.dismiss(animated: true)
  }
  
  private func accountDidChange() {
    isSignedIn = selectedUserAccount.hasCredentials() && selectedUserAccount.authState == .loggedIn
    
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
  
  func refreshSignInState() {
    let wasSignedIn = isSignedIn
    isSignedIn = selectedUserAccount.hasCredentials() && selectedUserAccount.authState == .loggedIn
    
    if wasSignedIn != isSignedIn {
      setupTableData()
    }
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
    lhs.hashValue == rhs.hashValue
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
    isLoading = true
    isSigningOut = false
    
    Task {
      try? await Task.sleep(nanoseconds: Constants.signInTimeoutSeconds)
      if isLoading {
        await MainActor.run {
          isLoading = false
        }
      }
    }
  }
  
  func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    isLoading = false
    isSigningOut = false
  }
  
  func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    isLoading = false
    isSigningOut = false
    accountDidChange()
  }
  
  func businessLogic(_ logic: TPPSignInBusinessLogic, didEncounterValidationError error: Error?, userFriendlyErrorTitle title: String?, andMessage message: String?) {
    isLoading = false
    isSigningOut = false
    
    if let error = error as? NSError, error.code == NSURLErrorCancelled {
      pinText = ""
    }
    
    let errorTitle = title ?? Strings.Error.loginErrorTitle
    let errorMessage = message ?? (error?.localizedDescription ?? Strings.Error.unknownRequestError)
    showError(title: errorTitle, message: errorMessage)
  }
  
  func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {
    isLoading = true
    isSigningOut = true
  }
  
  func businessLogic(_ logic: TPPSignInBusinessLogic, didEncounterSignOutError error: Error?, withHTTPStatusCode httpStatusCode: Int) {
    isLoading = false
    isSigningOut = false
    
    let title: String
    let message: String
    
    if httpStatusCode == 401 {
      title = "Unexpected Credentials"
      message = "Your username or password may have changed since the last time you logged in.\n\nIf you believe this is an error, please contact your library."
    } else if let error {
      title = "SettingsAccountViewControllerLogoutFailed"
      message = error.localizedDescription
    } else {
      title = "SettingsAccountViewControllerLogoutFailed"
      message = NSLocalizedString("An unknown error occurred while trying to sign out.", comment: "")
    }
    
    showError(title: NSLocalizedString(title, comment: ""), message: NSLocalizedString(message, comment: ""))
  }
  
  func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {
    isLoading = false
    isSigningOut = false
    setupTableData()
    accountDidChange()
  }
  
  func dismiss(animated flag: Bool, completion: (() -> Void)?) {
    guard let presented = UIApplication.shared.windows.first?.rootViewController?.presentedViewController else {
      return
    }
    presented.dismiss(animated: flag, completion: completion)
  }
  
  func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)?) {
    TPPPresentationUtils.safelyPresent(viewControllerToPresent, animated: flag, completion: completion)
  }
}

// MARK: - NYPLBasicAuthCredentialsProvider

extension AccountDetailViewModel: NYPLBasicAuthCredentialsProvider {
  var username: String? {
    let value = usernameText.isEmpty ? nil : usernameText
    Log.debug(#file, "Credentials provider - username: \(value ?? "nil")")
    return value
  }
  
  var pin: String? {
    let value = pinText.isEmpty ? "" : pinText
    Log.debug(#file, "Credentials provider - pin: '\(value)'")
    return value
  }
}
