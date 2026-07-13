//
//  DeveloperSettingsViewModel.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//
//  SwiftUI view model backing the Testing (developer settings) screen and the
//  app-level Advanced screen (PP-4788). This is a faithful, behavior-preserving
//  port of `TPPDeveloperSettingsTableViewController` — every toggle, action,
//  confirmation-alert title/message, and service call is reproduced exactly.
//  Only the presentation layer changed (UITableView → SwiftUI List); the
//  persistence keys and service entry points are untouched.
//

import Foundation
import SwiftUI
import MessageUI
import WebKit

/// Owns all Testing / Advanced screen state and actions. The two SwiftUI
/// screens (`DeveloperSettingsView`, `AppAdvancedSettingsView`) share this one
/// view model so the action logic is written once.
///
/// Toggle state is stored the same way the UIKit controller stored it:
///   - `TPPSettings` for beta-libraries + LCP passphrase
///   - `DebugSettings` (UserDefaults-backed) for badge logging / holds / error sims
///   - `RemoteFeatureFlags` local-override UserDefaults keys for the feature flags
/// The `@Published` mirrors are seeded from the live values on `init` and each
/// setter writes THROUGH to the same store the controller wrote to, so a flip
/// here is indistinguishable from a flip in the old UIKit screen.
@MainActor
final class DeveloperSettingsViewModel: ObservableObject {

    // MARK: - Dependencies (injected; default to the production graph)

    private let settings: TPPSettings
    private let accountsManager: AccountsManager
    private let debugSettings: DebugSettings
    private let featureFlags: RemoteFeatureFlags
    /// The UserDefaults instance the RemoteFeatureFlags overrides are written to.
    /// `RemoteFeatureFlags.shared` reads its overrides from `.standard`, and the
    /// UIKit controller wrote them via `UserDefaults.standard.set(...)`, so this
    /// defaults to `.standard` to preserve the exact read/write pairing.
    private let overrideDefaults: UserDefaults
    private let triageBotKeyAdmin = TriageBotKeyAdmin()

    // MARK: - Library Settings

    @Published var useBetaLibraries: Bool {
        didSet { settings.useBetaLibraries = useBetaLibraries }
    }

    @Published var enterLCPPassphraseManually: Bool {
        didSet { settings.enterLCPPassphraseManually = enterLCPPassphraseManually }
    }

    // MARK: - Triage Bot

    @Published var triageBotEnabled: Bool {
        didSet { overrideDefaults.set(triageBotEnabled, forKey: RemoteFeatureFlags.triageBotLocalOverrideKey) }
    }

    @Published var triageBotTicketSubmissionEnabled: Bool {
        didSet { overrideDefaults.set(triageBotTicketSubmissionEnabled, forKey: RemoteFeatureFlags.triageBotTicketSubmissionLocalOverrideKey) }
    }

    @Published var triageBotAIFallbackEnabled: Bool {
        didSet { overrideDefaults.set(triageBotAIFallbackEnabled, forKey: RemoteFeatureFlags.triageBotAIFallbackLocalOverrideKey) }
    }

    /// "Stored" / "Not set" trailing status for the Anthropic key row.
    @Published var anthropicKeyStatus: String

    // MARK: - Feature Flags

    @Published var inAppPlaybackNavEnabled: Bool {
        didSet { overrideDefaults.set(inAppPlaybackNavEnabled, forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey) }
    }

    @Published var appRatingForceEligible: Bool {
        didSet { overrideDefaults.set(appRatingForceEligible, forKey: RemoteFeatureFlags.appRatingForceEligibleLocalOverrideKey) }
    }

    // MARK: - Library Registry Debugging

    /// Bare host, or a full https:// URL. Mirrors
    /// `TPPSettings.customLibraryRegistryServer`.
    @Published var customRegistryInput: String

    // MARK: - Badge Testing (DEBUG)

    @Published var badgeLoggingEnabled: Bool {
        didSet { debugSettings.isBadgeLoggingEnabled = badgeLoggingEnabled }
    }

    @Published var testHoldsConfiguration: DebugSettings.TestHoldsConfiguration {
        didSet { debugSettings.testHoldsConfiguration = testHoldsConfiguration }
    }

    // MARK: - Error Simulation

    @Published var simulatedBorrowError: DebugSettings.SimulatedBorrowError {
        didSet { debugSettings.simulatedBorrowError = simulatedBorrowError }
    }

    @Published var simulatedSyncFailure: DebugSettings.SimulatedSyncFailure {
        didSet { debugSettings.simulatedSyncFailure = simulatedSyncFailure }
    }

    // MARK: - Async-loaded display state

    /// "Loading..." → actual FCM token (or "No token"). Matches the UIKit cell.
    @Published var fcmToken: String = "Loading..."

    /// Whether enhanced monitoring is on (drives the "🔍 Enhanced" badge on the
    /// Send Error Logs row).
    @Published var isEnhancedLoggingEnabled: Bool = false

    // MARK: - Init

    init(
        settings: TPPSettings = AppContainer.production().settings,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        debugSettings: DebugSettings = AppContainer.production().debugSettings,
        featureFlags: RemoteFeatureFlags = .shared,
        overrideDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.accountsManager = accountsManager
        self.debugSettings = debugSettings
        self.featureFlags = featureFlags
        self.overrideDefaults = overrideDefaults

        // Seed the published mirrors from the live values, exactly as the UIKit
        // cell builders did (they read the effective flag so QA sees live state).
        self.useBetaLibraries = settings.useBetaLibraries
        self.enterLCPPassphraseManually = settings.enterLCPPassphraseManually

        self.triageBotEnabled = featureFlags.isTriageBotEnabled
        self.triageBotTicketSubmissionEnabled = featureFlags.isTriageBotTicketSubmissionEnabled
        self.triageBotAIFallbackEnabled = featureFlags.isTriageBotAIFallbackEnabled
        self.anthropicKeyStatus = triageBotKeyAdmin.hasStoredKey ? "Stored" : "Not set"

        self.inAppPlaybackNavEnabled = featureFlags.isInAppPlaybackNavEnabled
        self.appRatingForceEligible = featureFlags.isAppRatingForceEligible

        self.customRegistryInput = settings.customLibraryRegistryServer ?? ""

        self.badgeLoggingEnabled = debugSettings.isBadgeLoggingEnabled
        self.testHoldsConfiguration = debugSettings.testHoldsConfiguration
        self.simulatedBorrowError = debugSettings.simulatedBorrowError
        self.simulatedSyncFailure = debugSettings.simulatedSyncFailure
    }

    // MARK: - Engineering-tools gating (verbatim port)

    /// Engineering tools render in DEBUG, simulator, and TestFlight, but are
    /// hidden from production App Store users. Pure, testable core — identical
    /// to `TPPDeveloperSettingsTableViewController.shouldShowEngineeringTools`.
    static func shouldShowEngineeringTools(receiptURL: URL?,
                                           fileExists: (String) -> Bool) -> Bool {
        guard let receiptURL else { return true }
        if receiptURL.lastPathComponent == "sandboxReceipt" { return true }
        let isProductionAppStore = receiptURL.lastPathComponent == "receipt"
            && fileExists(receiptURL.path)
        return !isProductionAppStore
    }

    /// Whether the engineering-only sections should be shown on this build.
    var showEngineeringTools: Bool {
        Self.shouldShowEngineeringTools(
            receiptURL: Bundle.main.appStoreReceiptURL,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    // MARK: - Async refreshers

    /// Loads the current FCM token into `fcmToken`. Mirrors `cellForFCMToken`.
    func loadFCMToken() async {
        let token = await NotificationService.shared.currentFCMToken()
        fcmToken = token ?? "No token"
    }

    /// Loads the enhanced-logging flag into `isEnhancedLoggingEnabled`. Mirrors
    /// the async `Task` in `cellForSendErrorLogs`.
    func loadEnhancedLoggingStatus() async {
        isEnhancedLoggingEnabled = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()
    }

    // MARK: - Triage Bot: Anthropic key

    /// Presents the paste/clear secure-text alert. Verbatim port of
    /// `presentAnthropicKeyEntry()`.
    func presentAnthropicKeyEntry(from presenter: UIViewController) {
        let hasKey = triageBotKeyAdmin.hasStoredKey
        let alert = UIAlertController(
            title: "Anthropic API Key",
            message: "Paste a key to enable the Triage Bot AI fallback on this device. "
                + "The key is stored only in this device's Keychain — never in the app "
                + "binary or source. Production users can't reach this screen, so their "
                + "AI fallback stays off.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "sk-ant-…"
            textField.isSecureTextEntry = true
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.spellCheckingType = .no
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            _ = self.triageBotKeyAdmin.save(raw)
            self.anthropicKeyStatus = self.triageBotKeyAdmin.hasStoredKey ? "Stored" : "Not set"
        })
        if hasKey {
            alert.addAction(UIAlertAction(title: "Clear Key", style: .destructive) { [weak self] _ in
                guard let self else { return }
                _ = self.triageBotKeyAdmin.clear()
                self.anthropicKeyStatus = self.triageBotKeyAdmin.hasStoredKey ? "Stored" : "Not set"
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    // MARK: - Feature Flags: rating actions

    /// Fires the app-rating book-completed trigger immediately. Verbatim from
    /// the `.featureFlags` row-2 tap handler.
    func triggerRatingPromptNow() {
        AppContainer.production().ratingPromptPresenter.handleTrigger(.bookCompleted)
    }

    /// Clears all app-rating engagement state, then confirms. Verbatim from the
    /// `.featureFlags` row-3 tap handler.
    func resetRatingState(from presenter: UIViewController) {
        AppContainer.production().appRatingService.resetEngagementState()
        let confirm = TPPAlertUtils.alert(title: "Rating State Reset",
                                          message: "All app-rating engagement signals have been cleared.")
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: confirm, viewController: presenter, animated: true, completion: nil)
    }

    // MARK: - Library Registry Debugging actions

    /// Clears the custom registry server. Verbatim from `TPPRegistryDebuggingCell.clear`.
    func clearCustomRegistry(from presenter: UIViewController) {
        customRegistryInput = ""
        settings.customLibraryRegistryServer = nil
        accountsManager.clearCache()
        presentAlert(title: "Configuration Updated",
                     message: "Registry has been reset to default",
                     from: presenter)
    }

    /// Sets the custom registry server + reloads. Verbatim from
    /// `TPPRegistryDebuggingCell.set`.
    func setCustomRegistry(from presenter: UIViewController) {
        accountsManager.clearCache()

        let text = customRegistryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            presentAlert(title: "Configuration Update Failed",
                         message: "Please enter a valid server URL",
                         from: presenter)
            return
        }

        settings.customLibraryRegistryServer = text
        let message = String(format: "Registry server: %@", text)
        accountsManager.clearCache()
        accountsManager.updateAccountSet { [weak self] isSuccess in
            guard let self else { return }
            if isSuccess {
                self.presentAlert(title: "Configuration Updated", message: message, from: presenter)
            } else {
                self.presentAlert(title: "Configuration Update Failed",
                                  message: "Please enter a valid server URL",
                                  from: presenter)
            }
        }
    }

    // MARK: - Data & Reset (support tier — surfaces on the Advanced screen)

    /// Clears the cache + image cache and confirms. Verbatim from the
    /// `.dataManagement` row-0 tap handler.
    func clearCachedData(from presenter: UIViewController) {
        accountsManager.clearCache()
        ImageCache.shared.clear()
        let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
        presenter.present(alert, animated: true, completion: nil)
    }

    /// "Reset This Library" confirmation → `performScopedReset`. Verbatim from
    /// `confirmResetThisLibrary()`.
    func confirmResetThisLibrary(from presenter: UIViewController) {
        presentResetConfirmation(
            title: "Reset This Library?",
            message: "Signs you out of the current library and deletes its downloads, bookmarks, and saved login on this device. Other libraries and your server loans/holds are not affected.",
            confirmTitle: "Reset Library",
            from: presenter
        ) { logic, done in logic.performScopedReset(completion: done) }
    }

    /// "Full Reset" confirmation → `performForceReset`. Verbatim from
    /// `confirmFullReset()`.
    func confirmFullReset(from presenter: UIViewController) {
        presentResetConfirmation(
            title: "Full Reset — All Libraries?",
            message: "Signs you out of EVERY library on this device and re-activates DRM device-wide. Use only if resetting a single library did not fix the problem. Server loans/holds are not affected.",
            confirmTitle: "Full Reset",
            from: presenter
        ) { logic, done in logic.performForceReset(completion: done) }
    }

    /// Builds the current-account business logic. Verbatim from
    /// `currentAccountBusinessLogic()`.
    private func currentAccountBusinessLogic() -> TPPSignInBusinessLogic? {
        let container = AppContainer.production()
        guard let accountId = container.accountsManager.currentAccountId,
              let registry = container.bookRegistry as? TPPBookRegistrySyncing else { return nil }
        return TPPSignInBusinessLogic(
            libraryAccountID: accountId,
            libraryAccountsProvider: container.accountsManager,
            urlSettingsProvider: container.settings,
            bookRegistry: registry,
            bookDownloadsCenter: container.downloadCenter,
            userAccountProvider: TPPUserAccount.self,
            uiDelegate: nil,
            drmAuthorizer: container.drmAuthorizerProvider()
        )
    }

    /// Presents the destructive confirmation alert. Verbatim from
    /// `presentResetConfirmation(...)`.
    private func presentResetConfirmation(title: String, message: String, confirmTitle: String,
                                          from presenter: UIViewController,
                                          action: @escaping (TPPSignInBusinessLogic, @escaping () -> Void) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { [weak self, weak presenter] _ in
            guard let self, let logic = self.currentAccountBusinessLogic() else { return }
            action(logic) {
                DispatchQueue.main.async {
                    let doneAlert = UIAlertController(title: "Reset complete", message: "You may need to sign in again.", preferredStyle: .alert)
                    doneAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter?.present(doneAlert, animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }

    // MARK: - Developer Tools: Send Error Logs (support tier — Advanced screen)

    /// Presents the "Device Info" action sheet-style alert with Copy/Preview/Send
    /// actions. Verbatim from `sendErrorLogs()`.
    func sendErrorLogs(from presenter: UIViewController) {
        Task { [weak presenter] in
            let deviceID = DeviceSpecificErrorMonitor.shared.getDeviceID()
            let sanitizedID = deviceID.replacingOccurrences(of: "-", with: "")
            let isEnhanced = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()

            let infoMessage = """
      Device ID: \(deviceID)
      Firebase Key: enhanced_error_logging_device_\(sanitizedID)
      Enhanced Logging: \(isEnhanced ? "✅ Enabled" : "❌ Disabled")

      Share the Firebase Key with support to enable enhanced error logging remotely.
      """

            await MainActor.run {
                guard let presenter else { return }
                let alert = UIAlertController(
                    title: "Device Info",
                    message: infoMessage,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Copy Device ID", style: .default) { _ in
                    UIPasteboard.general.string = deviceID
                })
                alert.addAction(UIAlertAction(title: "Copy Firebase Key", style: .default) { _ in
                    UIPasteboard.general.string = "enhanced_error_logging_device_\(sanitizedID)"
                })
                alert.addAction(UIAlertAction(title: "Preview Logs", style: .default) { [weak presenter] _ in
                    guard let presenter else { return }
                    self.previewLogs(from: presenter)
                })
                alert.addAction(UIAlertAction(title: "Send Logs", style: .default) { [weak presenter] _ in
                    Task {
                        guard let presenter else { return }
                        await ErrorLogExporter.shared.sendErrorLogs(from: presenter)
                    }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                presenter.present(alert, animated: true)
            }
        }
    }

    /// Presents the log-preview view controller. Verbatim from `previewLogs()`.
    func previewLogs(from presenter: UIViewController) {
        Task { [weak presenter] in
            let loadingAlert = UIAlertController(
                title: "Collecting Logs",
                message: "Please wait...",
                preferredStyle: .alert
            )
            await MainActor.run {
                presenter?.present(loadingAlert, animated: true)
            }

            let logData = await ErrorLogExporter.shared.collectLogsForPreview()

            await MainActor.run {
                loadingAlert.dismiss(animated: true) {
                    guard let presenter else { return }
                    let previewVC = LogPreviewViewController(logData: logData)
                    let nav = UINavigationController(rootViewController: previewVC)
                    nav.modalPresentationStyle = .fullScreen
                    previewVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
                        barButtonSystemItem: .done,
                        primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) }
                    )
                    presenter.present(nav, animated: true)
                }
            }
        }
    }

    // MARK: - Developer Tools: Email Audiobook Logs (engineering)

    /// Retained mail delegate — `MFMailComposeViewController.mailComposeDelegate`
    /// is weak, so the delegate must outlive the presentation. Held here on the
    /// view model for the composer's lifetime.
    private let audiobookMailDelegate = AudiobookMailComposeDelegate()

    /// Composes the audiobook-logs email. Verbatim from `emailAudiobookLogs()` —
    /// same recipient, subject, preferred-sender, and per-file attachments.
    func emailAudiobookLogs(from presenter: UIViewController) {
        guard MFMailComposeViewController.canSendMail() else {
            let alert = TPPAlertUtils.alert(title: "Mail Unavailable", message: "Cannot send email. Please configure an email account.")
            presenter.present(alert, animated: true, completion: nil)
            return
        }

        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = audiobookMailDelegate
        mailComposer.setSubject("Audiobook Logs")
        mailComposer.setToRecipients(["logs@thepalaceproject.org"])
        mailComposer.setPreferredSendingEmailAddress("LyrasisDebugging@email.com")

        let logger = AudiobookFileLogger()
        if let logsDirectoryUrl = logger.getLogsDirectoryUrl() {
            let fileManager = FileManager.default
            let logFiles = try? fileManager.contentsOfDirectory(at: logsDirectoryUrl, includingPropertiesForKeys: nil)

            logFiles?.forEach { logFileUrl in
                if let logData = try? Data(contentsOf: logFileUrl) {
                    mailComposer.addAttachmentData(logData, mimeType: "text/plain", fileName: logFileUrl.lastPathComponent)
                }
            }
        }

        presenter.present(mailComposer, animated: true, completion: nil)
    }

    // MARK: - Push Notification Testing (engineering)

    /// Copies the current FCM token to the pasteboard with confirmation. Verbatim
    /// from `copyFCMToken()`.
    func copyFCMToken(from presenter: UIViewController) {
        Task { [weak presenter] in
            let token = await NotificationService.shared.currentFCMToken()
            await MainActor.run {
                guard let presenter else { return }
                if let token {
                    UIPasteboard.general.string = token
                    let alert = TPPAlertUtils.alert(
                        title: "FCM Token Copied",
                        message: "Token copied to clipboard.\n\n\(token.prefix(20))...\(token.suffix(20))"
                    )
                    presenter.present(alert, animated: true)
                } else {
                    let alert = TPPAlertUtils.alert(
                        title: "No FCM Token",
                        message: "Push notifications may not be configured. Check that notification permissions are granted."
                    )
                    presenter.present(alert, animated: true)
                }
            }
        }
    }

    enum TestNotificationType {
        case holdAvailable
        case loanExpiry

        var title: String {
            switch self {
            case .holdAvailable: return "Your hold is ready"
            case .loanExpiry: return "Loan expiring soon"
            }
        }

        var body: String {
            switch self {
            case .holdAvailable: return "The title you reserved is available for checkout."
            case .loanExpiry: return "Your loan expires in 3 days. Return or renew to keep reading."
            }
        }

        var categoryIdentifier: String {
            switch self {
            case .holdAvailable: return HoldNotificationCategoryIdentifier
            case .loanExpiry: return "NYPLLoanExpiryNotificationCategory"
            }
        }

        var userInfo: [String: String] {
            switch self {
            case .holdAvailable: return ["type": "hold_available"]
            case .loanExpiry: return ["type": "loan_expiry"]
            }
        }
    }

    /// Presents the delay-picker action sheet then schedules. Verbatim port of
    /// `scheduleTestNotification(type:)` (minus the iPad-popover source-rect
    /// anchoring, which is provided by the SwiftUI `.confirmationDialog`/anchor).
    func scheduleTestNotification(type: TestNotificationType, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Schedule \(type.title)",
            message: "Choose a delay. Background the app before the notification fires to test tap-to-navigate.",
            preferredStyle: .actionSheet
        )

        for delay in [5, 10, 15, 30] {
            alert.addAction(UIAlertAction(title: "\(delay) seconds", style: .default) { [weak self, weak presenter] _ in
                guard let self, let presenter else { return }
                self.fireTestNotification(type: type, delay: TimeInterval(delay), from: presenter)
            })
        }

        alert.addAction(UIAlertAction(title: "Immediately", style: .default) { [weak self, weak presenter] _ in
            guard let self, let presenter else { return }
            self.fireTestNotification(type: type, delay: 1, from: presenter)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        presenter.present(alert, animated: true)
    }

    /// Fires the local test notification. Verbatim from `fireTestNotification`.
    private func fireTestNotification(type: TestNotificationType, delay: TimeInterval, from presenter: UIViewController) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak presenter] settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    let alert = TPPAlertUtils.alert(
                        title: "Notifications Disabled",
                        message: "Enable notifications in Settings → Palace to test push notifications."
                    )
                    presenter?.present(alert, animated: true)
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = type.title
            content.body = type.body
            content.sound = .default
            content.categoryIdentifier = type.categoryIdentifier
            content.userInfo = type.userInfo

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "palace-test-\(type.categoryIdentifier)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        let alert = TPPAlertUtils.alert(title: "Error", message: error.localizedDescription)
                        presenter?.present(alert, animated: true)
                    } else {
                        let alert = TPPAlertUtils.alert(
                            title: "Notification Scheduled",
                            message: "Firing in \(Int(delay))s. Background the app now to test tap-to-navigate."
                        )
                        presenter?.present(alert, animated: true)
                    }
                }
            }
        }
    }

    // MARK: - Error Simulation pickers (engineering)

    /// Presents the borrow-error picker action sheet. Verbatim from
    /// `showErrorSimulationPicker()`.
    func showErrorSimulationPicker(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Simulate Borrow Error",
            message: "Select an error type to simulate when borrowing books. The error will appear until you set it back to 'None'.",
            preferredStyle: .actionSheet
        )

        for errorType in DebugSettings.SimulatedBorrowError.allCases {
            let isSelected = debugSettings.simulatedBorrowError == errorType
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: errorType.displayName + checkmark, style: .default) { [weak self, weak presenter] _ in
                guard let self else { return }
                self.simulatedBorrowError = errorType

                if errorType != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Error Simulation Enabled",
                        message: "'\(errorType.displayName)' will be shown when you try to borrow any book. Remember to disable this when done testing."
                    )
                    presenter?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchorActionSheet(alert, to: presenter)
        presenter.present(alert, animated: true)
    }

    /// Presents the sync-failure picker action sheet. Verbatim from
    /// `showSyncFailurePicker()`.
    func showSyncFailurePicker(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Simulate Sync Failure",
            message: "Simulates the loans feed sync failing silently \u{2014} the exact scenario reported by users where hold notifications don't convert to checkouts.\n\nEnable, then pull-to-refresh on Holds or switch to foreground.",
            preferredStyle: .actionSheet
        )

        for failureType in DebugSettings.SimulatedSyncFailure.allCases {
            let isSelected = debugSettings.simulatedSyncFailure == failureType
            let checkmark = isSelected ? " \u{2713}" : ""

            alert.addAction(UIAlertAction(title: failureType.displayName + checkmark, style: .default) { [weak self, weak presenter] _ in
                guard let self else { return }
                self.simulatedSyncFailure = failureType

                if failureType != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Sync Failure Enabled",
                        message: "'\(failureType.displayName)' will be simulated on every sync. Go to Holds and pull to refresh \u{2014} notice how nothing happens and no error is shown.\n\nDisable when done testing."
                    )
                    presenter?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchorActionSheet(alert, to: presenter)
        presenter.present(alert, animated: true)
    }

    // MARK: - DEBUG-only actions

    #if DEBUG
    /// Presents the test-holds config picker action sheet. Verbatim from
    /// `showTestHoldsPicker()`.
    func showTestHoldsPicker(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Test Holds Configuration",
            message: "Select a test configuration to verify badge behavior.\n\nNote: This creates mock books with specific availability states. The app will use real data when set to 'None'.",
            preferredStyle: .actionSheet
        )

        for config in DebugSettings.TestHoldsConfiguration.allCases {
            let isSelected = debugSettings.testHoldsConfiguration == config
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: config.displayName + checkmark, style: .default) { [weak self, weak presenter] _ in
                guard let self else { return }
                self.testHoldsConfiguration = config

                NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
                NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)

                if config != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Test Holds Enabled",
                        message: "Badge should show: \(config.expectedBadgeCount)\n\nGo to the Reservations tab to see the test books. Remember to disable when done testing."
                    )
                    presenter?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchorActionSheet(alert, to: presenter)
        presenter.present(alert, animated: true)
    }

    /// Drives the ErrorDetail preview flow. Verbatim from `showPreviewErrorDetails()`.
    func showPreviewErrorDetails(from presenter: UIViewController) {
        Task { [weak presenter] in
            let tracker = ErrorActivityTracker.shared
            await tracker.log("User tapped 'Get' on 'The Great Gatsby'", category: .ui)
            await tracker.log("Initiating borrow for 'The Great Gatsby'", category: .borrow)
            await tracker.log("Authenticating with library credentials", category: .auth)
            await tracker.log("Auth succeeded — patron ID confirmed", category: .auth)
            await tracker.log("Requesting loan from https://circulation.example.org/loans", category: .network)
            await tracker.log("Received HTTP 403 from circulation server", category: .network)
            await tracker.log("[DEBUG] Preview: Simulated error for testing Error Details view", category: .general)

            let sampleProblemDoc = TPPProblemDocument.fromDictionary([
                "type": TPPProblemDocument.TypePatronLoanLimit,
                "title": "Loan limit reached",
                "status": 403,
                "detail": "You have reached your checkout limit of 10 items. Please return a title to borrow more."
            ])

            let sampleError = NSError(
                domain: "org.thepalaceproject.SimulatedError",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey: "Loan limit reached. You have checked out the maximum number of items.",
                    NSLocalizedRecoverySuggestionErrorKey: "Please return one or more titles before borrowing again."
                ]
            )

            let detail = await ErrorDetail.capture(
                title: "Borrow Failed",
                message: "Unable to borrow 'The Great Gatsby'. You have reached your loan limit.",
                error: sampleError,
                problemDocument: sampleProblemDoc,
                bookIdentifier: "urn:isbn:9780743273565",
                bookTitle: "The Great Gatsby"
            )

            await MainActor.run {
                guard let presenter else { return }
                let detailVC = ErrorDetailViewController(errorDetail: detail)
                let nav = UINavigationController(rootViewController: detailVC)
                presenter.present(nav, animated: true)
            }
        }
    }

    // MARK: - Reset Account Testing (DEBUG, PP-4282)

    /// Step 1: force the patron's app into the broken state. Verbatim from
    /// `simulateResetAccountStuckState()`.
    func simulateResetAccountStuckState(from presenter: UIViewController) {
        guard let account = accountsManager.currentAccount else {
            presentResetAccountAlert(title: "No Current Account",
                                     message: "Add and select a library first, then come back here.",
                                     from: presenter)
            return
        }

        let user = accountsManager.currentUserAccount

        account.hasUpdatedToken = true
        user.markCredentialsStale()

        let corruptedToken = "INVALID_SIMULATED_STUCK_STATE_BEARER_TOKEN"
        let pastDate = Date(timeIntervalSinceNow: -3600)
        user.setAuthToken(
            corruptedToken,
            barcode: user.barcode,
            pin: user.PIN,
            expirationDate: pastDate
        )

        UserDefaults.standard.removeObject(forKey: TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey)

        presentResetAccountAlert(
            title: "Stuck State Simulated",
            message: """
                Set on \(account.name):
                • hasUpdatedToken = true (push-reg short-circuit)
                • authState = credentialsStale
                • bearer token = corrupted (next borrow/sync will 401)
                • token expirationDate = 1 hour ago
                • nextOIDCSessionEphemeral flag = unset (cleared)

                Now: try a borrow or pull-to-refresh — should fail with auth error. THEN: Settings → Accounts → tap \(account.name) → Reset This Library Account.

                After Reset, come back here and tap Inspect — every line should look CLEAN (false / loggedOut / true for the ephemeral flag if the library is OIDC).

                NOTE — Reset Account does NOT clear Adobe DRM device activation. If a patron's symptom is "can borrow but can't READ", that's PP-3649 (Adobe DRM regression in 3.0.0) and lives in the private DRM submodule. Reset Account fixes the SAML/OIDC/push-token surfaces; PP-3649 needs its own fix.
                """,
            from: presenter
        )
    }

    /// Step 2: dump the state Reset Account touches. Verbatim from
    /// `inspectResetAccountState()`.
    func inspectResetAccountState(from presenter: UIViewController) {
        guard let account = accountsManager.currentAccount else {
            presentResetAccountAlert(title: "No Current Account",
                                     message: "Add and select a library first.",
                                     from: presenter)
            return
        }
        let user = accountsManager.currentUserAccount

        let ephemeralFlagSet = UserDefaults.standard.bool(forKey: TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey)

        let webDataStore = WKWebsiteDataStore.default()
        webDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self, weak presenter] records in
            DispatchQueue.main.async {
                guard let self, let presenter else { return }
                let lines = [
                    "Library: \(account.name) (\(account.uuid))",
                    "",
                    "hasUpdatedToken: \(account.hasUpdatedToken)",
                    "authState: \(user.authState)",
                    "hasCredentials: \(user.hasCredentials())",
                    "barcode present: \(user.barcode != nil)",
                    "PIN present: \(user.PIN != nil)",
                    "authToken present: \(user.authToken != nil)",
                    "",
                    "WKWebsiteDataStore records: \(records.count)",
                    "  (cookies, local storage, IndexedDB, etc. across ALL hosts — Reset wipes everything)",
                    "",
                    "nextOIDCSessionEphemeral flag: \(ephemeralFlagSet ? "SET (next OIDC session will be ephemeral)" : "unset (silent SSO active)")",
                    "",
                    "Expected after Reset: hasUpdatedToken=false, authState=loggedOut, hasCredentials=false, ephemeral flag SET (consumed-and-cleared by next OIDC sign-in)."
                ]
                self.presentResetAccountAlert(
                    title: "Account State",
                    message: lines.joined(separator: "\n"),
                    from: presenter
                )
            }
        }
    }

    /// Step 3: directly set the one-shot flag. Verbatim from
    /// `setNextOIDCEphemeralFlagForTesting()`.
    func setNextOIDCEphemeralFlagForTesting(from presenter: UIViewController) {
        UserDefaults.standard.set(true, forKey: TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey)
        presentResetAccountAlert(
            title: "Ephemeral Flag Set",
            message: """
                The next OIDC ASWebAuthenticationSession will be created with prefersEphemeralWebBrowserSession = true.

                To verify: sign out of an OIDC library, then sign back in. You should be forced through a real IdP authentication (not a silent SSO redirect).

                After that one session, the flag self-clears and silent SSO is restored.
                """,
            from: presenter
        )
    }

    private func presentResetAccountAlert(title: String, message: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
    #endif

    // MARK: - Helpers

    /// Presents a simple info alert on the given presenter (matches the
    /// registry cell's `showAlert`, which uses `TPPAlertUtils.alert`).
    private func presentAlert(title: String, message: String, from presenter: UIViewController) {
        let alert = TPPAlertUtils.alert(title: title, message: message)
        presenter.present(alert, animated: true, completion: nil)
    }

    /// Anchors an action-sheet's iPad popover to the center of the presenter so
    /// it doesn't crash on iPad (the UIKit version anchored to a table row rect).
    private func anchorActionSheet(_ alert: UIAlertController, to presenter: UIViewController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }
}

// MARK: - Audiobook mail delegate

/// Dismisses the audiobook-logs mail composer on finish. Mirrors the UIKit
/// controller's `mailComposeController(_:didFinishWith:error:)`, which simply
/// dismissed the composer.
@MainActor
private final class AudiobookMailComposeDelegate: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController,
                              didFinishWith result: MFMailComposeResult,
                              error: Error?) {
        controller.dismiss(animated: true, completion: nil)
    }
}
