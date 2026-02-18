//
//  AccountDetailView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import LocalAuthentication

struct AccountDetailView: View {
  typealias DisplayStrings = Strings.Settings
  
  @StateObject var viewModel: AccountDetailViewModel
  @Environment(\.dismiss) private var dismiss
  
  /// When true, forces showing sign-in form even if user has stale credentials.
  /// Used when presenting for re-authentication (e.g., from borrow flow after 401).
  private let forceReauthMode: Bool
  
  init(libraryAccountID: String, forceReauthMode: Bool = false) {
    _viewModel = StateObject(wrappedValue: AccountDetailViewModel(libraryAccountID: libraryAccountID))
    self.forceReauthMode = forceReauthMode
  }
  
  var body: some View {
    contentView
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .tabBar)
      .toolbarBackground(Color(UIColor.systemBackground), for: .tabBar)
      .alert(viewModel.alertTitle, isPresented: $viewModel.showingAlert) {
        Button(Strings.Generic.ok, role: .cancel) {}
      } message: {
        Text(viewModel.alertMessage)
      }
      .onAppear {
        viewModel.refreshSignInState()
      }
  }
  
  @ViewBuilder
  private var contentView: some View {
    if viewModel.isLoadingAuth {
      AccountDetailSkeletonView()
    } else {
      mainContent
    }
  }
  
  @ViewBuilder
  private var mainContent: some View {
    if shouldShowSignInPrompt {
      signInPromptView
    } else {
      accountDetailList
    }
  }
  
  private var shouldShowSignInPrompt: Bool {
    // Show sign-in prompt when:
    // 1. User is not signed in (no credentials), OR
    // 2. forceReauthMode is true AND credentials are stale (need re-authentication)
    //    This is used when the sign-in modal is presented for re-auth (e.g., borrow flow after 401)
    let needsSignIn = !viewModel.isSignedIn
    let needsReauth = forceReauthMode && viewModel.selectedUserAccount.authState == .credentialsStale
    
    let isOAuthOrSAML = viewModel.businessLogic.selectedAuthentication?.isOauth == true ||
                        viewModel.businessLogic.selectedAuthentication?.isSaml == true
    
    return (needsSignIn || needsReauth) && isOAuthOrSAML
  }
  
  // MARK: - Sign In Prompt View
  
  private var signInPromptView: some View {
    VStack(spacing: 0) {
      libraryHeaderSection
      SectionSeparator()
      signInMessageSection
      SectionSeparator()
      signInButtonSection
      reportIssueLinkIfAvailable
      Spacer()
    }
  }
  
  private var libraryHeaderSection: some View {
    HStack(spacing: Layout.logoSpacing) {
      if let logo = viewModel.libraryLogo {
        Image(uiImage: logo)
          .resizable()
          .scaledToFit()
          .frame(width: Layout.logoSize, height: Layout.logoSize)
      }
      
      Text(viewModel.libraryName)
        .font(.boldPalaceFont(size: Typography.libraryNameSize))
        .foregroundColor(.secondary)
        .horizontallyCentered()
    }
    .padding(.horizontal, Layout.horizontalPadding)
    .padding(.vertical, Layout.verticalPaddingLarge)
  }
  
  private var signInMessageSection: some View {
    Text(Strings.AccountDetail.signInMessage(libraryName: viewModel.libraryName))
      .font(.palaceFont(size: Typography.messageSize))
      .foregroundColor(.primary)
      .padding(.horizontal, Layout.horizontalPadding)
      .padding(.vertical, Layout.verticalPaddingLarge)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  
  @ViewBuilder
  private var signInButtonSection: some View {
    if let samlIdps = viewModel.businessLogic.selectedAuthentication?.samlIdps,
       viewModel.businessLogic.selectedAuthentication?.isSaml == true,
       !samlIdps.isEmpty {
      samlIDPList(idps: samlIdps)
    } else {
      singleSignInButton
    }
  }
  
  private func samlIDPList(idps: [OPDS2SamlIDP]) -> some View {
    VStack(spacing: Layout.buttonIDPSpacing) {
      ForEach(idps, id: \.displayName) { idp in
        HStack {
          ActionButtonView(
            title: Strings.Generic.signin,
            isLoading: viewModel.isLoading,
            action: { viewModel.selectSAMLIDP(idp) }
          )
          .frame(width: Layout.buttonWidth)
          Spacer()
        }
      }
    }
    .padding(.horizontal, Layout.horizontalPadding)
    .padding(.top, Layout.verticalPaddingLarge)
    // Force view refresh when isLoading changes
    .id("samlIDPList-\(viewModel.isLoading)")
  }
  
  private var singleSignInButton: some View {
    HStack {
      ActionButtonView(
        title: Strings.Generic.signin,
        isLoading: viewModel.isLoading,
        action: { viewModel.signIn() }
      )
      .frame(width: Layout.buttonWidth)
      Spacer()
    }
    .padding(.horizontal, Layout.horizontalPadding)
    .padding(.top, Layout.verticalPaddingLarge)
    // Force view refresh when isLoading changes
    .id("signInButton-\(viewModel.isLoading)")
  }
  
  @ViewBuilder
  private var reportIssueLinkIfAvailable: some View {
    if viewModel.selectedAccount?.supportEmail != nil || viewModel.selectedAccount?.supportURL != nil {
      HStack {
        reportIssueLink
        Spacer()
      }
      .padding(.horizontal, Layout.horizontalPadding)
      .padding(.vertical, Layout.verticalPaddingLarge)
    }
  }
  
  @ViewBuilder
  private var reportIssueLink: some View {
    if viewModel.selectedAccount?.supportEmail != nil {
      Button(action: handleReportIssue) {
        Text(DisplayStrings.reportIssue)
          .font(.palaceFont(size: Typography.messageSize))
          .foregroundColor(Color(TPPConfiguration.mainColor()))
          .underline()
      }
    } else if viewModel.selectedAccount?.supportURL != nil {
      NavigationLink(destination: reportIssueWebView) {
        Text(DisplayStrings.reportIssue)
          .font(.palaceFont(size: Typography.messageSize))
          .foregroundColor(Color(TPPConfiguration.mainColor()))
          .underline()
      }
    }
  }
  
  // MARK: - Account Detail List
  
  private var accountDetailList: some View {
    List {
      accountHeaderSection
      
      ForEach(Array(viewModel.tableData.enumerated()), id: \.offset) { sectionIndex, section in
        Section {
          ForEach(Array(section.enumerated()), id: \.element) { _, cellType in
            cellView(for: cellType)
          }
        } footer: {
          sectionFooter(for: sectionIndex)
        }
      }
    }
    .listStyle(GroupedListStyle())
  }
  
  @ViewBuilder
  private func sectionFooter(for index: Int) -> some View {
    if index == 0 && viewModel.businessLogic.shouldShowEULALink() {
      eulaFooter
    } else if index == 1 && viewModel.businessLogic.shouldShowSyncButton() {
      syncFooter
    }
  }
  
  @ViewBuilder
  private var accountHeaderSection: some View {
    HStack(spacing: Layout.logoSpacingList) {
      if let logo = viewModel.libraryLogo {
        Image(uiImage: logo)
          .resizable()
          .scaledToFit()
          .frame(width: Layout.logoSizeList, height: Layout.logoSizeList)
      }
      
      Text(viewModel.libraryName)
        .font(.system(size: Typography.headerSize, weight: .bold))
        .foregroundColor(.secondary)
      
      Spacer()
    }
    .padding(.vertical, Layout.verticalPaddingSmall)
    .listRowBackground(Color.clear)
    .listRowInsets(EdgeInsets())
  }
  
  @ViewBuilder
  private func cellView(for cellType: CellType) -> some View {
    switch cellType {
    case .barcodeImage:
      barcodeImageCell
    case .barcode:
      barcodeInputCell
    case .pin:
      pinInputCell
    case .logInSignOut:
      logInSignOutCell
    case .ageCheck:
      ageCheckCell
    case .syncButton:
      syncToggleCell
    case .registration:
      registrationCell
    case .advancedSettings:
      advancedSettingsCell
    case .privacyPolicy:
      privacyPolicyCell
    case .contentLicense:
      contentLicenseCell
    case .reportIssue:
      reportIssueCell
    case .passwordReset:
      passwordResetCell
    case .authMethod(let auth):
      authMethodCell(auth: auth)
    case .samlIDP(let idp):
      samlIDPCell(idp: idp)
    case .infoHeader(let text):
      infoHeaderCell(text: text)
    default:
      EmptyView()
    }
  }
  
  // MARK: - Cell Views
  
  private var barcodeImageCell: some View {
    VStack(spacing: Layout.verticalPaddingMedium) {
      if let barcodeImage = viewModel.barcodeImage {
        if viewModel.showBarcode {
          Image(uiImage: barcodeImage)
            .resizable()
            .scaledToFit()
            .frame(height: Layout.barcodeHeight)
          
          Text(viewModel.selectedUserAccount.authorizationIdentifier ?? "")
            .font(.system(.body))
            .padding(.bottom, Layout.barcodeBottomPadding)
        }
        
        Button(action: { withAnimation { viewModel.showBarcode.toggle() } }) {
          Text(viewModel.showBarcode ? DisplayStrings.hideBarcode : DisplayStrings.showBarcode)
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
      }
    }
    .padding(.vertical, Layout.verticalPaddingSmall)
  }
  
  private var barcodeInputCell: some View {
    HStack {
      TextField(
        viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? DisplayStrings.barcodeOrUsername,
        text: $viewModel.usernameText
      )
      .textContentType(.username)
      .autocapitalization(.none)
      .autocorrectionDisabled()
      .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.patronIDKeyboard))
      .disabled(viewModel.isSignedIn)
      .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
      .accessibilityIdentifier(AccessibilityID.SignIn.barcodeField)
      
      if !viewModel.isSignedIn && viewModel.businessLogic.selectedAuthentication?.supportsBarcodeScanner == true {
        Button(action: { viewModel.scanBarcode() }) {
          Image(systemName: "camera")
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
        .accessibilityLabel(Strings.Generic.scanBarcode)
      }
    }
    .padding(.vertical, Layout.verticalPaddingInput)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
  }
  
  private var pinInputCell: some View {
    HStack {
      if viewModel.isPINHidden {
        SecureField(
          viewModel.businessLogic.selectedAuthentication?.pinLabel ?? DisplayStrings.pin,
          text: $viewModel.pinText
        )
        .textContentType(.password)
        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
        .disabled(viewModel.isSignedIn)
        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
        .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
      } else {
        TextField(
          viewModel.businessLogic.selectedAuthentication?.pinLabel ?? DisplayStrings.pin,
          text: $viewModel.pinText
        )
        .textContentType(.password)
        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
        .disabled(viewModel.isSignedIn)
        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
        .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
      }
      
      if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
        Button(action: { viewModel.togglePINVisibility() }) {
          Text(viewModel.isPINHidden ? DisplayStrings.show : DisplayStrings.hide)
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
      }
    }
    .padding(.vertical, Layout.verticalPaddingInput)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
  }
  
  private var logInSignOutCell: some View {
    Button(action: { viewModel.signIn() }) {
      HStack {
        if viewModel.isLoading {
          ZStack {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle())
            Text(viewModel.isSigningOut ? DisplayStrings.signingOut : DisplayStrings.signingIn)
              .foregroundColor(.primary)
          }
          .horizontallyCentered()
        } else {
          if viewModel.isSignedIn {
            Text(DisplayStrings.signOut)
              .foregroundColor(Color(TPPConfiguration.mainColor()))
              .horizontallyCentered()
          } else {
            Text(Strings.Generic.signin)
              .foregroundColor(viewModel.canSignIn ? Color(TPPConfiguration.mainColor()) : .secondary)
          }
        }
      }
    }
    .disabled(!viewModel.canSignIn && !viewModel.isSignedIn)
    .accessibilityIdentifier(AccessibilityID.SignIn.signInButton)
  }
  
  private var ageCheckCell: some View {
    HStack {
      Text(DisplayStrings.ageVerification)
        .font(.system(.body))
      
      Spacer()
      
      if TPPSettings.shared.userPresentedAgeCheck {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if !TPPSettings.shared.userPresentedAgeCheck {
        viewModel.performAgeCheck()
      }
    }
  }
  
  private var syncToggleCell: some View {
    HStack {
      Text(DisplayStrings.syncBookmarks)
        .font(.system(.body))
      
      Spacer()
      
      Toggle("", isOn: $viewModel.isSyncEnabled)
        .labelsHidden()
        .tint(.green)
        .accessibilityIdentifier("signIn.syncBookmarksToggle")
        .onChange(of: viewModel.isSyncEnabled) { newValue in
          viewModel.updateSync(enabled: newValue)
        }
    }
  }
  
  private var registrationCell: some View {
    Button(action: { viewModel.openRegistration() }) {
      Text(DisplayStrings.signUpForCard)
        .foregroundColor(Color(TPPConfiguration.mainColor()))
        .horizontallyCentered()
    }
  }
  
  private var advancedSettingsCell: some View {
    NavigationLink(destination: AdvancedSettingsView(accountID: viewModel.businessLogic.libraryAccountID)) {
      Text(DisplayStrings.advanced)
        .font(.system(.body))
    }
  }
  
  private var privacyPolicyCell: some View {
    NavigationLink(destination: privacyPolicyView) {
      Text(DisplayStrings.privacyPolicy)
        .font(.system(.body))
    }
  }
  
  private var contentLicenseCell: some View {
    NavigationLink(destination: contentLicenseView) {
      Text(DisplayStrings.contentLicenses)
        .font(.system(.body))
    }
  }
  
  @ViewBuilder
  private var privacyPolicyView: some View {
    if let url = viewModel.selectedAccount?.details?.getLicenseURL(.privacyPolicy) {
      UIViewControllerWrapper(
        RemoteHTMLViewController(
          URL: url,
          title: DisplayStrings.privacyPolicy,
          failureMessage: Strings.Error.pageLoadFailedError
        ),
        updater: { _ in }
      )
      .navigationBarTitle(Text(DisplayStrings.privacyPolicy))
    }
  }
  
  @ViewBuilder
  private var contentLicenseView: some View {
    if let url = viewModel.selectedAccount?.details?.getLicenseURL(.contentLicenses) {
      UIViewControllerWrapper(
        RemoteHTMLViewController(
          URL: url,
          title: DisplayStrings.contentLicenses,
          failureMessage: Strings.Error.pageLoadFailedError
        ),
        updater: { _ in }
      )
      .navigationBarTitle(Text(DisplayStrings.contentLicenses))
    }
  }
  
  @ViewBuilder
  private var reportIssueCell: some View {
    if viewModel.selectedAccount?.supportEmail != nil {
      Button(action: handleReportIssue) {
        Text(DisplayStrings.reportIssue)
          .font(.system(.body))
      }
    } else if viewModel.selectedAccount?.supportURL != nil {
      NavigationLink(destination: reportIssueWebView) {
        Text(DisplayStrings.reportIssue)
          .font(.system(.body))
      }
    }
  }
  
  @ViewBuilder
  private var reportIssueWebView: some View {
    if let url = viewModel.selectedAccount?.supportURL {
      UIViewControllerWrapper(
        BundledHTMLViewController(
          fileURL: url,
          title: viewModel.selectedAccount?.name ?? ""
        ),
        updater: { _ in }
      )
      .navigationBarTitle(Text(DisplayStrings.reportIssue))
    }
  }
  
  private var passwordResetCell: some View {
    Button(action: { viewModel.resetPassword() }) {
      Text(DisplayStrings.forgotPassword)
        .font(.system(.body))
    }
  }
  
  private func authMethodCell(auth: AccountDetails.Authentication) -> some View {
    Button(action: { viewModel.selectAuthMethod(auth) }) {
      Text(auth.methodDescription ?? "")
        .font(.system(.body))
        .foregroundColor(.primary)
    }
  }
  
  private func samlIDPCell(idp: OPDS2SamlIDP) -> some View {
    Button(action: { viewModel.selectSAMLIDP(idp) }) {
      HStack {
        if viewModel.isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
          Text(DisplayStrings.signingIn)
        } else {
          Text(idp.displayName ?? "")
        }
      }
      .font(.system(.body))
      .foregroundColor(.primary)
    }
  }
  
  private func infoHeaderCell(text: String) -> some View {
    Text(text)
      .font(.system(.footnote))
      .foregroundColor(.secondary)
      .listRowBackground(Color.clear)
  }
  
  // MARK: - Footer Views
  
  private var eulaFooter: some View {
    NavigationLink(destination: eulaView) {
      Text(DisplayStrings.eulaAgreement)
        .font(.system(.caption))
        .foregroundColor(.blue)
        .underline()
    }
    .padding(.top, Layout.verticalPaddingSmall)
  }
  
  @ViewBuilder
  private var eulaView: some View {
    if let account = viewModel.selectedAccount {
      EULAView(account: account)
    }
  }
  
  private var syncFooter: some View {
    Text(DisplayStrings.syncDescription)
      .font(.system(.caption))
      .foregroundColor(.secondary)
      .padding(.top, Layout.verticalPaddingSmall)
  }
  
  // MARK: - Actions
  
  private func handleReportIssue() {
    guard let email = viewModel.selectedAccount?.supportEmail,
          let topVC = topViewController() else {
      return
    }
    
    ProblemReportEmail.sharedInstance.beginComposing(
      to: email.rawValue,
      presentingViewController: topVC,
      book: nil as TPPBook?
    )
  }
  
  // MARK: - Helper Methods
  
  private func keyboardType(for loginKeyboard: LoginKeyboard?) -> UIKeyboardType {
    switch loginKeyboard {
    case .email:
      .emailAddress
    case .numeric:
      .numberPad
    default:
      .asciiCapable
    }
  }
  
  private func topViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else {
      return nil
    }
    
    var current = root
    while let presented = current.presentedViewController {
      current = presented
    }
    return current
  }
}
