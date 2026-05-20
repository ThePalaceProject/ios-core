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
        let needsSignIn = !viewModel.isSignedIn
        let needsReauth = forceReauthMode && viewModel.selectedUserAccount.authState == .credentialsStale

        let isBrowserBasedAuth = viewModel.businessLogic.selectedAuthentication?.isOauth == true ||
            viewModel.businessLogic.selectedAuthentication?.isSaml == true ||
            viewModel.businessLogic.selectedAuthentication?.isOidc == true

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
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.verticalPaddingLarge)
    }

    private var signInMessageSection: some View {
        Text(Strings.AccountDetail.signInMessage(libraryName: viewModel.libraryName))
            .palaceFont(.footnote)
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
                ActionButtonView(
                    title: Strings.Generic.signin,
                    isLoading: viewModel.isLoading,
                    action: { viewModel.selectSAMLIDP(idp) }
                )
            }
        }
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, Layout.verticalPaddingLarge)
        // Force view refresh when isLoading changes
        .id("samlIDPList-\(viewModel.isLoading)")
    }

    private var singleSignInButton: some View {
        ActionButtonView(
            title: Strings.Generic.signin,
            isLoading: viewModel.isLoading,
            action: { viewModel.signIn() }
        )
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, Layout.verticalPaddingLarge)
        // Force view refresh when isLoading changes
        .id("signInButton-\(viewModel.isLoading)")
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
                    .foregroundColor(Color(TPPConfiguration.mainColor()))
                    .underline()
            })
        } else if viewModel.selectedAccount?.supportURL != nil {
            NavigationLink(destination: reportIssueWebView, label: {
                Text(DisplayStrings.reportIssue)
                    .palaceFont(.footnote)
                    .foregroundColor(Color(TPPConfiguration.mainColor()))
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
                .foregroundColor(.secondary)

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
        switch cellType {
        case .barcodeImage:
            barcodeImageCell
        case .barcode:
            barcodeInputCell
        case .pin:
            pinInputCell
        case .logInSignOut:
            logInSignOutCell
        case .resetAccount:
            resetAccountCell
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
                        .accessibilityLabel(NSLocalizedString("Library barcode", comment: "Barcode image accessibility"))

                    Text(viewModel.selectedUserAccount.authorizationIdentifier ?? "")
                        .font(.system(.body))
                        .padding(.bottom, Layout.barcodeBottomPadding)
                }

                Button(action: { withAnimation(UIAccessibility.isReduceMotionEnabled ? .none : .default) { viewModel.showBarcode.toggle() } }, label: {
                    Text(viewModel.showBarcode ? DisplayStrings.hideBarcode : DisplayStrings.showBarcode)
                        .foregroundColor(Color(TPPConfiguration.mainColor()))
                })
            }
        }
        .padding(.vertical, Layout.verticalPaddingSmall)
    }

    private var barcodeInputCell: some View {
        // HelpSpot 17923 — replaced the default SwiftUI `.placeholderText`
        // ghost (patrons consistently report it as "the field looks
        // disabled, I can't tap it") with an explicit caption Text above
        // the field. The caption is .accessibilityHidden(true) because
        // VoiceOver already announces the label below via the
        // TextField's .accessibilityLabel — duplicating it would announce
        // the field name twice.
        let label = viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? DisplayStrings.barcodeOrUsername
        return VStack(alignment: .leading, spacing: Layout.verticalPaddingSmall) {
            Text(String(format: DisplayStrings.tapToEnter, label))
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField(label, text: $viewModel.usernameText)
                .textContentType(.username)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.patronIDKeyboard))
                .disabled(viewModel.isSignedIn)
                .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
                .accessibilityIdentifier(AccessibilityID.SignIn.barcodeField)
                .accessibilityLabel(viewModel.businessLogic.selectedAuthentication?.patronIDLabel ?? DisplayStrings.barcodeOrUsername)
                .focused($focusedField, equals: .barcode)
                .onSubmit { focusedField = .pin }
                .submitLabel(.next)
        }
        .padding(.vertical, Layout.verticalPaddingInput)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private var pinLabel: String {
        viewModel.businessLogic.selectedAuthentication?.pinLabel ?? DisplayStrings.pin
    }

    private var pinInputCell: some View {
        // HelpSpot 17923 — caption Text above the field for the same
        // reason as `barcodeInputCell`. The HStack with show/hide button
        // stays inline (the toggle is paired with the field visually);
        // only the caption row sits above. .accessibilityHidden(true)
        // is deliberate — the SecureField/TextField below already carries
        // .accessibilityLabel(pinLabel), so VoiceOver would otherwise
        // announce "PIN" twice.
        VStack(alignment: .leading, spacing: Layout.verticalPaddingSmall) {
            Text(String(format: DisplayStrings.tapToEnter, pinLabel))
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            HStack {
                if viewModel.isPINHidden {
                    SecureField(pinLabel, text: $viewModel.pinText)
                        .textContentType(.password)
                        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
                        .disabled(viewModel.isSignedIn)
                        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
                        .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
                        .accessibilityLabel(pinLabel)
                        .focused($focusedField, equals: .pin)
                        .onSubmit { if viewModel.canSignIn { viewModel.signIn() } }
                        .submitLabel(.go)
                } else {
                    TextField(pinLabel, text: $viewModel.pinText)
                        .textContentType(.password)
                        .keyboardType(keyboardType(for: viewModel.businessLogic.selectedAuthentication?.pinKeyboard))
                        .disabled(viewModel.isSignedIn)
                        .foregroundColor(viewModel.isSignedIn ? .secondary : .primary)
                        .accessibilityIdentifier(AccessibilityID.SignIn.pinField)
                        .accessibilityLabel(pinLabel)
                        .focused($focusedField, equals: .pin)
                        .onSubmit { if viewModel.canSignIn { viewModel.signIn() } }
                        .submitLabel(.go)
                }

                if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                    Button(action: { viewModel.togglePINVisibility() }, label: {
                        Text(viewModel.isPINHidden ? DisplayStrings.show : DisplayStrings.hide)
                            .foregroundColor(Color(TPPConfiguration.mainColor()))
                    })
                }
            }
        }
        .padding(.vertical, Layout.verticalPaddingInput)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .contain)
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
                            .foregroundColor(.primary)
                    }
                    .horizontallyCentered()
                } else if viewModel.isSignedIn {
                    Text(DisplayStrings.signOut)
                        .foregroundColor(Color(TPPConfiguration.mainColor()))
                        .horizontallyCentered()
                } else {
                    Text(Strings.Generic.signin)
                        .foregroundColor(viewModel.canSignIn ? Color(TPPConfiguration.mainColor()) : .secondary)
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

    /// PP-4282 / HelpSpot 17716: destructive "Reset This Library Account"
    /// button. Patron-self-service recovery for stuck-state cases that
    /// Sign Out alone can't fix (CM DELETE hangs, broken-state-survives-
    /// reinstall, etc.). See `TPPSignInBusinessLogic+ForceReset.swift`.
    private var resetAccountCell: some View {
        Button(action: {
            viewModel.confirmResetAccount()
        }, label: {
            Text(NSLocalizedString("Reset This Library Account", comment: "Destructive reset-account button label"))
                .foregroundColor(.red)
                .horizontallyCentered()
        })
        .buttonStyle(.plain)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityLabel(NSLocalizedString("Reset This Library Account", comment: "Accessibility label for the destructive reset-account button"))
        .accessibilityHint(NSLocalizedString("Deletes downloads, bookmarks, and sign-in for this library so you can start fresh", comment: "Accessibility hint for the reset-account button"))
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
                    .foregroundColor(.green)
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
                .onChange(of: viewModel.isSyncEnabled) { newValue in
                    viewModel.updateSync(enabled: newValue)
                }
        }
    }

    private var registrationCell: some View {
        Button(action: { viewModel.openRegistration() }, label: {
            Text(DisplayStrings.signUpForCard)
                .foregroundColor(Color(TPPConfiguration.mainColor()))
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
                .foregroundColor(.secondary)
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
                .foregroundColor(.primary)
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
            .foregroundColor(.primary)
        })
    }

    private func infoHeaderCell(text: String) -> some View {
        Text(text)
            .font(.system(.footnote))
            .foregroundColor(.secondary)
            .listRowBackground(Color.clear)
    }

    // MARK: - Footer Views

    private var eulaFooter: some View {
        NavigationLink(destination: eulaView, label: {
            Text(DisplayStrings.eulaAgreement)
                .font(.system(.caption))
                .foregroundColor(.blue)
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
            book: nil as TPPBook?,
            libraryUUID: viewModel.selectedAccount?.uuid
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
