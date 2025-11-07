//
//  AccountDetailView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import LocalAuthentication

struct AccountDetailView: View {
  @StateObject var viewModel: AccountDetailViewModel
  @Environment(\.dismiss) private var dismiss
  
  init(libraryAccountID: String) {
    _viewModel = StateObject(wrappedValue: AccountDetailViewModel(libraryAccountID: libraryAccountID))
  }
  
  var body: some View {
    ZStack {
      if viewModel.isLoadingAuth {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      } else {
        mainContent
      }
    }
    .navigationTitle(NSLocalizedString("Account", comment: ""))
    .navigationBarTitleDisplayMode(.inline)
    .alert(viewModel.alertTitle, isPresented: $viewModel.showingAlert) {
      Button(Strings.Generic.ok, role: .cancel) {}
    } message: {
      Text(viewModel.alertMessage)
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
    // Show the clean sign-in prompt for OAuth and SAML when not signed in
    !viewModel.isSignedIn && 
    (viewModel.businessLogic.selectedAuthentication?.isOauth == true ||
     viewModel.businessLogic.selectedAuthentication?.isSaml == true)
  }
  
  // MARK: - Sign In Prompt View (For Screenshot Design)
  private var signInPromptView: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        if let logo = viewModel.libraryLogo {
          Image(uiImage: logo)
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 44)
        }
                
        Text(viewModel.libraryName)
          .font(.boldPalaceFont(size: 19))
          .foregroundColor(.secondary)
          .horizontallyCentered()
      }
      .padding(.horizontal, 25)
      .padding(.vertical, 40)
      
      Rectangle()
        .fill(Color(UIColor.separator))
        .frame(height: 0.5)
      
      // Sign in message
      Text(viewModel.signInMessage)
        .font(.palaceFont(size: 14))
        .foregroundColor(.primary)
        .padding(.horizontal, 25)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
      
      Rectangle()
        .fill(Color(UIColor.separator))
        .frame(height: 0.5)
      
      // Sign in button or SAML IDP list
      if viewModel.businessLogic.selectedAuthentication?.isSaml == true,
         let samlIdps = viewModel.businessLogic.selectedAuthentication?.samlIdps,
         !samlIdps.isEmpty {

        VStack(spacing: 12) {
          ForEach(samlIdps, id: \.displayName) { idp in
            HStack {
              samlIDPButton(idp: idp)
                .frame(width: 100)
              Spacer()
            }
          }
        }
        .padding(.horizontal, 25)
        .padding(.top, 40)
      } else {
        HStack {
          signInButton
            .frame(width: 100)
          Spacer()
        }
        .padding(.horizontal, 25)
        .padding(.top, 40)
      }
      
      // Report an Issue link
      if let _ = viewModel.selectedAccount?.supportEmail ?? viewModel.selectedAccount?.supportURL {
        HStack {
          reportIssueLink
          Spacer()
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 40)
      }
      
      Spacer()
    }
  }
  
  private var reportIssueLink: some View {
    Button(action: {
      if let email = viewModel.selectedAccount?.supportEmail, let topVC = topViewController() {
        ProblemReportEmail.sharedInstance.beginComposing(
          to: email.rawValue,
          presentingViewController: topVC,
          book: nil as TPPBook?
        )
      } else if let url = viewModel.selectedAccount?.supportURL, let topVC = topViewController() {
        let vc = BundledHTMLViewController(
          fileURL: url,
          title: viewModel.selectedAccount?.name ?? ""
        )
        vc.hidesBottomBarWhenPushed = true
        topVC.navigationController?.pushViewController(vc, animated: true)
      }
    }) {
      Text(NSLocalizedString("Report an Issue", comment: ""))
        .font(.palaceFont(size: 14))
        .foregroundColor(Color(TPPConfiguration.mainColor()))
        .underline()
    }
  }
  
  private func samlIDPButton(idp: OPDS2SamlIDP) -> some View {
    Button(action: {
      Log.info(#file, "SAML IDP button tapped: \(idp.displayName ?? "unknown")")
      viewModel.selectSAMLIDP(idp)
    }) {
      ZStack {
        if viewModel.isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .tint(buttonTextColor)
        }
        Text(viewModel.isLoading ? NSLocalizedString("Signing In", comment: "") : ("Sign In"))
          .font(.system(size: 17, weight: .semibold))
          .opacity(viewModel.isLoading ? 0.5 : 1)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background(buttonBackgroundColor)
      .foregroundColor(buttonTextColor)
      .cornerRadius(8)
    }
    .disabled(viewModel.isLoading)
    .buttonStyle(.plain)
  }
  
  @ViewBuilder
  private var signInButton: some View {
    Button(action: {
      Log.info(#file, "Sign In button tapped in view")
      viewModel.signIn()
    }) {
      ZStack {
        if viewModel.isLoading {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .tint(buttonTextColor)
        }
        Text(viewModel.isLoading ? NSLocalizedString("Signing In", comment: "") : NSLocalizedString("Sign In", comment: ""))
          .font(.system(size: 17, weight: .semibold))
      }
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background(buttonBackgroundColor)
      .foregroundColor(buttonTextColor)
      .cornerRadius(8)
    }
    .disabled(viewModel.isLoading)
    .buttonStyle(.plain)
    .onTapGesture {
      Log.info(#file, "Sign In button tap gesture detected")
    }
  }
  
  @Environment(\.colorScheme) private var colorScheme
  
  private var isDarkBackground: Bool {
    colorScheme == .dark
  }
  
  private var buttonBackgroundColor: Color {
    isDarkBackground ? .white : .black
  }
  
  private var buttonTextColor: Color {
    isDarkBackground ? .black : .white
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
          if sectionIndex == 0 && viewModel.businessLogic.shouldShowEULALink() {
            eulaFooter
          } else if sectionIndex == 1 && viewModel.businessLogic.shouldShowSyncButton() {
            syncFooter
          }
        }
      }
    }
    .listStyle(GroupedListStyle())
  }
  
  @ViewBuilder
  private var accountHeaderSection: some View {
    HStack(spacing: 12) {
      if let logo = viewModel.libraryLogo {
        Image(uiImage: logo)
          .resizable()
          .scaledToFit()
          .frame(width: 50, height: 50)
      }
      
      Text(viewModel.libraryName)
        .font(.system(size: 18, weight: .bold))
        .foregroundColor(.secondary)
      
      Spacer()
    }
    .padding(.vertical, 8)
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
    VStack(spacing: 12) {
      if let barcodeImage = viewModel.barcodeImage {
        if viewModel.showBarcode {
          Image(uiImage: barcodeImage)
            .resizable()
            .scaledToFit()
            .frame(height: 100)
          
          Text(viewModel.selectedUserAccount.authorizationIdentifier ?? "")
            .font(.system(.body))
            .padding(.bottom, 8)
        }
        
        Button(action: { withAnimation { viewModel.showBarcode.toggle() } }) {
          Text(viewModel.showBarcode ? NSLocalizedString("Hide Barcode", comment: "") : NSLocalizedString("Show Barcode", comment: ""))
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
      }
    }
    .padding(.vertical, 8)
  }
  
  private var barcodeInputCell: some View {
    HStack {
      TextField(
        viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? NSLocalizedString("Barcode or Username", comment: ""),
        text: $viewModel.usernameText
      )
      .textContentType(.username)
      .autocapitalization(.none)
      .autocorrectionDisabled()
      .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.patronIDKeyboard))
      .disabled(viewModel.isSignedIn)
      .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
      
      if !viewModel.isSignedIn && viewModel.businessLogic.selectedAuthentication?.supportsBarcodeScanner == true {
        Button(action: { viewModel.scanBarcode() }) {
          Image(systemName: "camera")
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
      }
    }
    .padding(.vertical, 2)
  }
  
  private var pinInputCell: some View {
    HStack {
      if viewModel.isPINHidden {
        SecureField(
          viewModel.businessLogic.selectedAuthentication?.pinLabel ?? NSLocalizedString("PIN", comment: ""),
          text: $viewModel.pinText
        )
        .textContentType(.password)
        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
        .disabled(viewModel.isSignedIn)
        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
      } else {
        TextField(
          viewModel.businessLogic.selectedAuthentication?.pinLabel ?? NSLocalizedString("PIN", comment: ""),
          text: $viewModel.pinText
        )
        .textContentType(.password)
        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
        .disabled(viewModel.isSignedIn)
        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
      }
      
      if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
        Button(action: { viewModel.togglePINVisibility() }) {
          Text(viewModel.isPINHidden ? NSLocalizedString("Show", comment: "") : NSLocalizedString("Hide", comment: ""))
            .foregroundColor(Color(TPPConfiguration.mainColor()))
        }
      }
    }
    .padding(.vertical, 2)
  }
  
  private var logInSignOutCell: some View {
    Button(action: { viewModel.signIn() }) {
      HStack {
        if viewModel.isLoading {
          ZStack {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle())
            Text(viewModel.isSignedIn ? NSLocalizedString("Signing out", comment: "") : NSLocalizedString("Verifying", comment: ""))
              .foregroundColor(.primary)
          }
          .horizontallyCentered()
        } else {
          if viewModel.isSignedIn {
            Text(NSLocalizedString("Sign out", comment: ""))
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
  }
  
  private var ageCheckCell: some View {
    HStack {
      Text(NSLocalizedString("Age Verification", comment: ""))
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
      Text(NSLocalizedString("Sync Bookmarks", comment: ""))
        .font(.system(.body))
      
      Spacer()
      
      Toggle("", isOn: $viewModel.isSyncEnabled)
        .labelsHidden()
        .onChange(of: viewModel.isSyncEnabled) { _ in
          viewModel.toggleSync()
        }
    }
  }
  
  private var registrationCell: some View {
    Button(action: { viewModel.openRegistration() }) {
      HStack {
        Spacer()
        Text(NSLocalizedString("Sign up for a library card", comment: ""))
          .foregroundColor(Color(TPPConfiguration.mainColor()))
        Spacer()
      }
    }
  }
  
  private var advancedSettingsCell: some View {
    NavigationLink(destination: AdvancedSettingsView(accountID: viewModel.businessLogic.libraryAccountID)) {
      Text(NSLocalizedString("Advanced", comment: ""))
        .font(.system(.body))
    }
  }
  
  private var privacyPolicyCell: some View {
    NavigationLink(destination: privacyPolicyView) {
      Text(NSLocalizedString("Privacy Policy", comment: ""))
        .font(.system(.body))
    }
  }
  
  private var contentLicenseCell: some View {
    NavigationLink(destination: contentLicenseView) {
      Text(NSLocalizedString("Content Licenses", comment: ""))
        .font(.system(.body))
    }
  }
  
  private var reportIssueCell: some View {
    Button(action: {
      if let email = viewModel.selectedAccount?.supportEmail, let topVC = topViewController() {
        ProblemReportEmail.sharedInstance.beginComposing(
          to: email.rawValue,
          presentingViewController: topVC,
          book: nil as TPPBook?
        )
      } else if let url = viewModel.selectedAccount?.supportURL, let topVC = topViewController() {
        let vc = BundledHTMLViewController(
          fileURL: url,
          title: viewModel.selectedAccount?.name ?? ""
        )
        vc.hidesBottomBarWhenPushed = true
        topVC.navigationController?.pushViewController(vc, animated: true)
      }
    }) {
      Text(NSLocalizedString("Report an Issue", comment: ""))
        .font(.system(.body))
    }
  }
  
  private var passwordResetCell: some View {
    Button(action: { viewModel.resetPassword() }) {
      Text(NSLocalizedString("Forgot your password?", comment: ""))
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
          Text(NSLocalizedString("Signing In", comment: ""))
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
      Text(NSLocalizedString("By signing in, you agree to the End User License Agreement.", comment: ""))
        .font(.system(.caption))
        .foregroundColor(.blue)
        .underline()
    }
    .padding(.top, 8)
  }
  
  @ViewBuilder
  private var eulaView: some View {
    if let account = viewModel.selectedAccount {
      EULAView(account: account)
    } else {
      EmptyView()
    }
  }
  
  private var syncFooter: some View {
    Text(NSLocalizedString("Save your reading position and bookmarks to all your other devices.", comment: ""))
      .font(.system(.caption))
      .foregroundColor(.secondary)
      .padding(.top, 8)
  }
  
  // MARK: - Helper Views
  @ViewBuilder
  private var privacyPolicyView: some View {
    if let url = viewModel.selectedAccount?.details?.getLicenseURL(.privacyPolicy) {
      UIViewControllerWrapper(
        RemoteHTMLViewController(
          URL: url,
          title: NSLocalizedString("Privacy Policy", comment: ""),
          failureMessage: Strings.Error.pageLoadFailedError
        ),
        updater: { _ in }
      )
    }
  }
  
  @ViewBuilder
  private var contentLicenseView: some View {
    if let url = viewModel.selectedAccount?.details?.getLicenseURL(.contentLicenses) {
      UIViewControllerWrapper(
        RemoteHTMLViewController(
          URL: url,
          title: NSLocalizedString("Content Licenses", comment: ""),
          failureMessage: Strings.Error.pageLoadFailedError
        ),
        updater: { _ in }
      )
    }
  }
  
  // MARK: - Helper Methods
  private func keyboardType(for loginKeyboard: LoginKeyboard?) -> UIKeyboardType {
    switch loginKeyboard {
    case .email:
      return .emailAddress
    case .numeric:
      return .numberPad
    default:
      return .asciiCapable
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

