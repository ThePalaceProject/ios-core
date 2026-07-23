//
//  AccountDetailView.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import SwiftUI
import PalacePreferences
import LocalAuthentication

struct AccountDetailView: View {
    typealias DisplayStrings = Strings.Settings

    enum SignInField: Hashable {
        case barcode, pin
    }

    @StateObject var viewModel: AccountDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: SignInField?

    /// When true, forces showing sign-in form even if user has stale credentials.
    /// Used when presenting for re-authentication (e.g., from borrow flow after 401).
    private let forceReauthMode: Bool
    private let settings: TPPSettings

    init(libraryAccountID: String, appContainer: AppContainer, forceReauthMode: Bool = false) {
        _viewModel = StateObject(wrappedValue: AccountDetailViewModel(
            libraryAccountID: libraryAccountID,
            appContainer: appContainer
        ))
        self.forceReauthMode = forceReauthMode
        self.settings = appContainer.settings
    }

    var body: some View {
        contentView
            .navigationTitle(DisplayStrings.account)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color(UIColor.systemBackground), for: .tabBar)
            .alert(viewModel.alertTitle, isPresented: $viewModel.showingAlert, actions: {
                Button(Strings.Generic.ok, role: .cancel) {}
            }, message: {
                Text(viewModel.alertMessage)
            })
            .onAppear {
                viewModel.forceReauthMode = forceReauthMode
                viewModel.refreshSignInState()
            }
            .task {
                // Auto-trigger OIDC browser flow when presented for re-auth
                // with stale credentials — no manual "Sign In" tap needed.
                // The ASWebAuthenticationSession presents its own system browser sheet.
                if forceReauthMode,
                   viewModel.selectedUserAccount.authState == .credentialsStale,
                   viewModel.businessLogic.selectedAuthentication?.isOidc == true {
                    viewModel.signIn()
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoadingAuth || DebugSettings.forceSkeletons {
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
        let needsSignIn = !viewModel.isSignedIn
        let needsReauth = forceReauthMode && viewModel.selectedUserAccount.authState == .credentialsStale

        let isBrowserBasedAuth = viewModel.businessLogic.selectedAuthentication?.isBrowserBased == true

        return (needsSignIn || needsReauth) && isBrowserBasedAuth
    }

    // MARK: - Sign In Prompt View

    private var signInPromptView: some View {
        VStack(spacing: 0) {
            libraryHeaderSection
            SectionSeparator()
            signInMessageSection
            SectionSeparator()
            signInButtonSection
            registrationLinkIfAvailable
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
                    .accessibilityHidden(true) // Library name provides context
            }

            Text(viewModel.libraryName)
                .palaceFont(.headline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPaddingLarge)
    }

    private var signInMessageSection: some View {
        Text(Strings.AccountDetail.signInMessage(libraryName: viewModel.libraryName))
            .palaceFont(.footnote)
            .foregroundStyle(.primary)
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
                ActionButtonView(
                    title: Strings.Generic.signin,
                    isLoading: viewModel.isLoading,
                    action: { viewModel.selectSAMLIDP(idp) }
                )
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, Layout.verticalPaddingLarge)
    }

    private var singleSignInButton: some View {
        ActionButtonView(
            title: Strings.Generic.signin,
            isLoading: viewModel.isLoading,
            action: { viewModel.signIn() }
        )
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, Layout.verticalPaddingLarge)
    }

    @ViewBuilder
    private var registrationLinkIfAvailable: some View {
        if viewModel.businessLogic.registrationIsPossible() {
            ActionButtonView(
                title: DisplayStrings.signUpForCard,
                isLoading: false,
                style: .secondary,
                action: { viewModel.openRegistration() }
            )
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.verticalPaddingMedium)
        }
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
            Button(action: handleReportIssue, label: {
                Text(DisplayStrings.reportIssue)
                    .palaceFont(.footnote)
                    .foregroundStyle(Color(TPPConfiguration.mainColor()))
                    .underline()
            })
        } else if viewModel.selectedAccount?.supportURL != nil {
            NavigationLink(destination: reportIssueWebView, label: {
                Text(DisplayStrings.reportIssue)
                    .palaceFont(.footnote)
                    .foregroundStyle(Color(TPPConfiguration.mainColor()))
                    .underline()
            })
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
                            .accessibilityElement(children: .contain)
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
                    .accessibilityHidden(true) // Library name provides context
            }

            Text(viewModel.libraryName)
                .palaceFont(.headline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(
            top: Layout.verticalPaddingSmall,
            leading: Layout.horizontalPadding,
            bottom: Layout.verticalPaddingSmall,
            trailing: Layout.horizontalPadding
        ))
    }

    @ViewBuilder
    private func cellView(for cellType: CellType) -> some View {
        // F-011 class-of-bug guard
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
        case .about:
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
                        .accessibilityLabel(NSLocalizedString("Library barcode", comment: "Barcode image accessibility"))

                    Text(viewModel.selectedUserAccount.authorizationIdentifier ?? "")
                        .font(.system(.body))
                        .padding(.bottom, Layout.barcodeBottomPadding)
                }

                Button(action: { withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { viewModel.showBarcode.toggle() } }, label: {
                    Text(viewModel.showBarcode ? DisplayStrings.hideBarcode : DisplayStrings.showBarcode)
                        .foregroundStyle(Color(TPPConfiguration.mainColor()))
                })
            }
        }
        .padding(.vertical, Layout.verticalPaddingSmall)
    }

    private var barcodeInputCell: some View {
        let label = viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? DisplayStrings.barcodeOrUsername
        // PP-4421: explicit prompt with `.secondary` foreground overrides the
        // default `.placeholderText` (~30% gray) that patrons read as a
        // disabled field. Entered text retains its own .foregroundColor
        // below — only the empty-state hint is darkened.
        return TextField(label, text: $viewModel.usernameText, prompt: Text(label).foregroundStyle(.secondary))
            .textContentType(.username)
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.patronIDKeyboard))
            .disabled(viewModel.isSignedIn)
            .foregroundStyle(viewModel.isSignedIn ? .secondary : .primary)
            .accessibilityIdentifier(AccessibilityID.SignIn.barcodeField)
            .accessibilityLabel(label)
            .focused($focusedField, equals: .barcode)
            .onSubmit { focusedField = .pin }
            .submitLabel(.next)
            .padding(.vertical, Layout.verticalPaddingInput)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private var pinLabel: String {
        viewModel.businessLogic.selectedAuthentication?.pinLabel ?? DisplayStrings.pin
    }

    private var pinInputCell: some View {
        // PP-4421: explicit prompt with `.secondary` foreground overrides
        // the default `.placeholderText` (~30% gray) that patrons read as
        // a disabled field. Both visible (TextField) and masked (SecureField)
        // branches get the same prompt — empty-state hint is darker, entered
        // text retains its own .foregroundColor below.
        VStack(alignment: .leading, spacing: 0) {
        HStack {
            if viewModel.isPINHidden {
                SecureField(pinLabel, text: $viewModel.pinText, prompt: Text(pinLabel).foregroundStyle(.secondary))
                    .textContentType(.password)
                    .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
                    .disabled(viewModel.isSignedIn)
                    .foregroundStyle(viewModel.isSignedIn ? .secondary : .primary)
                    .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
                    .accessibilityLabel(pinLabel)
                    .focused($focusedField, equals: .pin)
                    .onSubmit { if viewModel.canSignIn { viewModel.signIn() } }
                    .submitLabel(.go)
            } else {
                TextField(pinLabel, text: $viewModel.pinText, prompt: Text(pinLabel).foregroundStyle(.secondary))
                    .textContentType(.password)
                    .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
                    .disabled(viewModel.isSignedIn)
                    .foregroundStyle(viewModel.isSignedIn ? .secondary : .primary)
                    .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
                    .accessibilityLabel(pinLabel)
                    .focused($focusedField, equals: .pin)
                    .onSubmit { if viewModel.canSignIn { viewModel.signIn() } }
                    .submitLabel(.go)
            }

            if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                Button(action: { viewModel.togglePINVisibility() }, label: {
                    Text(viewModel.isPINHidden ? DisplayStrings.show : DisplayStrings.hide)
                        .foregroundStyle(Color(TPPConfiguration.mainColor()))
                })
            }
        }
        .padding(.vertical, Layout.verticalPaddingInput)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .contain)

            inlineFormError
        }
        .accessibleAnimation(PalaceMotion.emphasized,
                             value: Self.shouldShowInlineFormError(showingAlert: viewModel.showingAlert,
                                                                   message: viewModel.alertMessage))
    }

    /// Inline error row rendered directly UNDER the PIN field. Presentation
    /// mirror of the SAME existing `@Published` `alertMessage`/`showingAlert` —
    /// no new view-model state, no auth-logic change. Its placement inside
    /// `pinInputCell` naturally scopes it to the sign-in form; the existing
    /// `.alert` (see `body`) is kept for non-form / system errors.
    @ViewBuilder
    private var inlineFormError: some View {
        if Self.shouldShowInlineFormError(showingAlert: viewModel.showingAlert,
                                          message: viewModel.alertMessage) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
                Text(viewModel.alertMessage)
                    .palaceFont(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.bottom, Layout.verticalPaddingSmall)
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var logInSignOutCell: some View {
        Button(action: {
            if viewModel.isSignedIn {
                viewModel.confirmSignOut()
            } else {
                viewModel.signIn()
            }
        }, label: {
            HStack {
                if viewModel.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text(viewModel.isSigningOut ? DisplayStrings.signingOut : DisplayStrings.signingIn)
                            .foregroundStyle(.primary)
                    }
                    .horizontallyCentered()
                } else if viewModel.isSignedIn {
                    Text(DisplayStrings.signOut)
                        .foregroundStyle(Color(TPPConfiguration.mainColor()))
                        .horizontallyCentered()
                } else {
                    Text(Strings.Generic.signin)
                        .foregroundStyle(viewModel.canSignIn ? Color(TPPConfiguration.mainColor()) : Color.secondary)
                        .horizontallyCentered()
                }
            }
        })
        .buttonStyle(.plain)
        .disabled(!viewModel.canSignIn && !viewModel.isSignedIn)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityIdentifier(AccessibilityID.SignIn.signInButton)
        .accessibilityLabel(viewModel.isSignedIn ? DisplayStrings.signOut : Strings.Generic.signin)
        .accessibilityAddTraits(.isButton)
        .accessibilityRemoveTraits(.isStaticText)
    }

    private var ageCheckCell: some View {
        HStack {
            Text(DisplayStrings.ageVerification)
                .font(.system(.body))

            Spacer()

            if settings.userPresentedAgeCheck {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(NSLocalizedString("Verified", comment: "Age check verified"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !settings.userPresentedAgeCheck {
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
                .onChange(of: viewModel.isSyncEnabled) { _, newValue in
                    viewModel.updateSync(enabled: newValue)
                }
        }
    }

    private var registrationCell: some View {
        Button(action: { viewModel.openRegistration() }, label: {
            Text(DisplayStrings.signUpForCard)
                .foregroundStyle(Color(TPPConfiguration.mainColor()))
                .horizontallyCentered()
        })
    }

    private var advancedSettingsCell: some View {
        NavigationLink(destination: AdvancedSettingsView(accountID: viewModel.businessLogic.libraryAccountID), label: {
            Text(DisplayStrings.advanced)
                .font(.system(.body))
        })
    }

    private var privacyPolicyCell: some View {
        NavigationLink(destination: privacyPolicyView, label: {
            Text(DisplayStrings.privacyPolicy)
                .font(.system(.body))
        })
    }

    private var contentLicenseCell: some View {
        NavigationLink(destination: contentLicenseView, label: {
            Text(DisplayStrings.contentLicenses)
                .font(.system(.body))
        })
    }

    @ViewBuilder
    private var privacyPolicyView: some View {
        // BUG-005 hardening: anchor `.navigationBarTitle` outside the
        // `if let` to prevent SwiftUI from leaking the previous push's
        // title when the URL is unavailable. Same fix as the
        // contentLicenseView / reportIssueWebView destinations.
        // `@ViewBuilder` is required so the if/else is wrapped in
        // `_ConditionalContent` before `SwiftUI.Group` sees it — without
        // it Xcode 26's type-checker can't pick `Group.init(content:)`
        // and cascades to a CodingKey overload.
        SwiftUI.Group {
            if let url = viewModel.selectedAccount?.details?.getLicenseURL(.privacyPolicy) {
                UIViewControllerWrapper(
                    RemoteHTMLViewController(
                        URL: url,
                        title: DisplayStrings.privacyPolicy,
                        failureMessage: Strings.Error.pageLoadFailedError
                    ),
                    updater: { _ in }
                )
            } else {
                unavailableInfoView
            }
        }
        .navigationBarTitle(Text(DisplayStrings.privacyPolicy))
    }

    @ViewBuilder
    private var contentLicenseView: some View {
        // BUG-005: `.navigationBarTitle` must live *outside* the `if let`.
        // When the destination body is empty SwiftUI silently falls back to
        // the previous push's title, so a nil URL would render the
        // "Report an Issue" title here. Anchoring the title on the outer
        // view (and providing a non-empty unavailable-state body) prevents
        // both the title leak and the blank-screen symptoms.
        // See `privacyPolicyView` for the SwiftUI.Group + @ViewBuilder
        // typecheck-disambiguation rationale.
        SwiftUI.Group {
            if let url = viewModel.selectedAccount?.details?.getLicenseURL(.contentLicenses) {
                UIViewControllerWrapper(
                    RemoteHTMLViewController(
                        URL: url,
                        title: DisplayStrings.contentLicenses,
                        failureMessage: Strings.Error.pageLoadFailedError
                    ),
                    updater: { _ in }
                )
            } else {
                unavailableInfoView
            }
        }
        .navigationBarTitle(Text(DisplayStrings.contentLicenses))
    }

    private var unavailableInfoView: some View {
        VStack {
            Spacer()
            Text(Strings.Error.pageLoadFailedError)
                .palaceFont(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.horizontalPadding)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var reportIssueCell: some View {
        if viewModel.selectedAccount?.supportEmail != nil {
            Button(action: handleReportIssue, label: {
                Text(DisplayStrings.reportIssue)
                    .font(.system(.body))
            })
        } else if viewModel.selectedAccount?.supportURL != nil {
            NavigationLink(destination: reportIssueWebView, label: {
                Text(DisplayStrings.reportIssue)
                    .font(.system(.body))
            })
        }
    }

    @ViewBuilder
    private var reportIssueWebView: some View {
        // BUG-001 + BUG-005: anchor `.navigationBarTitle` outside the
        // optional binding so the title is committed even when the URL is
        // unavailable. Use `RemoteHTMLViewController` (designed for http
        // URLs with activity indicator + failure alert) rather than
        // `BundledHTMLViewController` (designed for bundled file:// URLs)
        // — `supportURL` is always a remote http URL fetched from the
        // library's auth document.
        // See `privacyPolicyView` for the SwiftUI.Group + @ViewBuilder
        // typecheck-disambiguation rationale.
        SwiftUI.Group {
            if let url = viewModel.selectedAccount?.supportURL {
                UIViewControllerWrapper(
                    RemoteHTMLViewController(
                        URL: url,
                        title: DisplayStrings.reportIssue,
                        failureMessage: Strings.Error.pageLoadFailedError
                    ),
                    updater: { _ in }
                )
            } else {
                unavailableInfoView
            }
        }
        .navigationBarTitle(Text(DisplayStrings.reportIssue))
    }

    private var passwordResetCell: some View {
        Button(action: { viewModel.resetPassword() }, label: {
            Text(DisplayStrings.forgotPassword)
                .font(.system(.body))
        })
    }

    private func authMethodCell(auth: AccountDetails.Authentication) -> some View {
        Button(action: { viewModel.selectAuthMethod(auth) }, label: {
            Text(auth.methodDescription ?? "")
                .font(.system(.body))
                .foregroundStyle(.primary)
        })
    }

    private func samlIDPCell(idp: OPDS2SamlIDP) -> some View {
        Button(action: { viewModel.selectSAMLIDP(idp) }, label: {
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
            .foregroundStyle(.primary)
        })
    }

    private func infoHeaderCell(text: String) -> some View {
        Text(text)
            .font(.system(.footnote))
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
    }

    // MARK: - Footer Views

    private var eulaFooter: some View {
        NavigationLink(destination: eulaView, label: {
            Text(DisplayStrings.eulaAgreement)
                .font(.system(.caption))
                .foregroundStyle(.blue)
                .underline()
        })
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
            .foregroundStyle(.secondary)
            .padding(.top, Layout.verticalPaddingSmall)
    }

    // MARK: - Actions

    private func handleReportIssue() {
        guard let email = viewModel.selectedAccount?.supportEmail,
              let topVC = topViewController() else {
            return
        }

        let ctx = viewModel.problemReportContext
        ProblemReportEmail.sharedInstance.beginComposing(
            to: email.rawValue,
            presentingViewController: topVC,
            book: nil as TPPBook?,
            patronIdentifier: ctx.patronIdentifier,
            libraryName: ctx.libraryName
        )
    }

    // MARK: - Helper Methods

    /// Pure presentation decision: show the inline form-error row when there is
    /// an active alert AND a non-empty message. Kept static + Bool-only so it is
    /// unit-testable without spinning up the view or the view model, and so it
    /// carries no authentication/credential logic — it only reflects existing
    /// `@Published` state.
    static func shouldShowInlineFormError(showingAlert: Bool, message: String) -> Bool {
        showingAlert && !message.isEmpty
    }

    private func keyboardType(for loginKeyboard: LoginKeyboard?) -> UIKeyboardType {
        // F-011 class-of-bug guard
        switch loginKeyboard {
        case .email:
            .emailAddress
        case .numeric:
            .numberPad
        case .standard, .some(.none), nil:
            .asciiCapable
        }
    }

    private func topViewController() -> UIViewController? {
        guard let root = UIApplication.shared.mainKeyWindow?.rootViewController else {
            return nil
        }

        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}
