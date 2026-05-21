import MessageUI
import SwiftUI
import WebKit
import PalaceCatalog

@objcMembers
class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, MFMailComposeViewControllerDelegate {

    weak var tableView: UITableView!
    var loadingView: UIView?
    enum Section: Int, CaseIterable {
        case librarySettings = 0
        case libraryRegistryDebugging
        case dataManagement
        case developerTools
        case pushNotificationTesting
        case badgeTesting
        case errorSimulation
        #if DEBUG
        case mockBackend
        case resetAccountTesting
        #endif
    }

    private let fcmTokenCellIdentifier = "fcmTokenCell"
    private let betaLibraryCellIdentifier = "betaLibraryCell"
    private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
    private let clearCacheCellIdentifier = "clearCacheCell"
    private let emailLogsCellIdentifier = "emailLogsCell"
    private let sendErrorLogsCellIdentifier = "sendErrorLogsCell"
    private let errorSimulationCellIdentifier = "errorSimulationCell"
    private let badgeLoggingCellIdentifier = "badgeLoggingCell"
    private let testHoldsCellIdentifier = "testHoldsCell"

    private var pushNotificationsStatus = false
    private let settings: TPPSettings
    private let accountsManager: AccountsManager
    private let debugSettings: DebugSettings

    required init(
        settings: TPPSettings = AppContainer.production().settings,
        accountsManager: AccountsManager = AppContainer.production().accountsManager,
        debugSettings: DebugSettings = AppContainer.production().debugSettings
    ) {
        self.settings = settings
        self.accountsManager = accountsManager
        self.debugSettings = debugSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func librarySwitchDidChange(sender: UISwitch!) {
        settings.useBetaLibraries = sender.isOn
    }

    func enterLCPPassphraseSwitchDidChange(sender: UISwitch) {
        settings.enterLCPPassphraseManually = sender.isOn
    }

    // MARK: - UIViewController

    override func loadView() {
        self.view = UITableView(frame: CGRect.zero, style: .grouped)
        self.tableView = self.view as? UITableView
        self.tableView.delegate = self
        self.tableView.dataSource = self

        self.title = Strings.TPPDeveloperSettingsTableViewController.developerSettingsTitle
        self.view.backgroundColor = TPPConfiguration.backgroundColor()

        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: betaLibraryCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: lcpPassphraseCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: clearCacheCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: emailLogsCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: sendErrorLogsCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: errorSimulationCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: badgeLoggingCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: testHoldsCellIdentifier)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let sectionType = Section(rawValue: section) else { return 0 }
        switch sectionType {
        case .librarySettings: return 2
        case .developerTools: return 2
        case .pushNotificationTesting: return 3
        case .badgeTesting:
            #if DEBUG
            return 2
            #else
            return 0  // Hide badge testing in production builds
            #endif
        case .errorSimulation:
            #if DEBUG
            return 3  // Simulate Borrow Error + Simulate Sync Failure + Preview Error Details
            #else
            return 2  // Simulate Borrow Error + Simulate Sync Failure (available in TestFlight for QA)
            #endif
        #if DEBUG
        case .mockBackend: return 1
        case .resetAccountTesting: return 3  // simulate stuck state + inspect + set ephemeral flag
        #endif
        default: return 1
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let sectionType = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }
        switch sectionType {
        case .librarySettings:
            switch indexPath.row {
            case 0: return cellForBetaLibraries()
            default: return cellForLCPPassphrase()
            }
        case .libraryRegistryDebugging: return cellForCustomRegsitry()
        case .dataManagement: return cellForClearCache()
        case .developerTools:
            switch indexPath.row {
            case 0: return cellForSendErrorLogs()
            default: return cellForEmailAudiobookLogs()
            }
        case .pushNotificationTesting:
            switch indexPath.row {
            case 0: return cellForFCMToken()
            case 1: return cellForTestHoldNotification()
            default: return cellForTestLoanExpiryNotification()
            }
        case .badgeTesting:
            #if DEBUG
            switch indexPath.row {
            case 0: return cellForBadgeLogging()
            default: return cellForTestHolds()
            }
            #else
            return UITableViewCell()  // Should never be called in production (0 rows)
            #endif
        case .errorSimulation:
            switch indexPath.row {
            case 0: return cellForErrorSimulation()
            case 1: return cellForSyncFailureSimulation()
            default:
                #if DEBUG
                return cellForPreviewErrorDetails()
                #else
                return UITableViewCell()
                #endif
            }
        #if DEBUG
        case .mockBackend:
            return cellForMockBackend()
        case .resetAccountTesting:
            switch indexPath.row {
            case 0: return cellForResetAccountSimulateStuck()
            case 1: return cellForResetAccountInspect()
            default: return cellForResetAccountSetEphemeral()
            }
        #endif
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionType = Section(rawValue: section) else { return nil }
        switch sectionType {
        case .librarySettings:
            return "Library Settings"
        case .libraryRegistryDebugging:
            return "Library Registry Debugging"
        case .dataManagement:
            return "Data Management"
        case .developerTools:
            return "Developer Tools"
        case .pushNotificationTesting:
            return "Push Notification Testing"
        case .badgeTesting:
            #if DEBUG
            return "Badge Testing"
            #else
            return nil
            #endif
        case .errorSimulation:
            return "Error Simulation (Testing)"
        #if DEBUG
        case .mockBackend:
            return "Mock Backend"
        case .resetAccountTesting:
            return "Reset Account Testing (PP-4282)"
        #endif
        }
    }

    private func createSwitch(isOn: Bool, action: Selector) -> UISwitch {
        let switchControl = UISwitch()
        switchControl.isOn = isOn
        switchControl.addTarget(self, action: action, for: .valueChanged)
        return switchControl
    }

    private func cellForBetaLibraries() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: betaLibraryCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(betaLibraryCellIdentifier)")
        }
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enable Hidden Libraries"
        cell.accessoryView = createSwitch(isOn: settings.useBetaLibraries, action: #selector(librarySwitchDidChange))
        return cell
    }

    private func cellForLCPPassphrase() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: lcpPassphraseCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(lcpPassphraseCellIdentifier)")
        }
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enter LCP Passphrase Manually"
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.textLabel?.minimumScaleFactor = 0.5
        cell.accessoryView = createSwitch(isOn: settings.enterLCPPassphraseManually, action: #selector(enterLCPPassphraseSwitchDidChange))
        return cell
    }

    private func cellForCustomRegsitry() -> UITableViewCell {
        let cell = TPPRegistryDebuggingCell()
        cell.delegate = self
        return cell
    }

    private func cellForClearCache() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: clearCacheCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(clearCacheCellIdentifier)")
        }
        cell.selectionStyle = .none
        cell.textLabel?.text = "Clear Cached Data"
        return cell
    }

    private func cellForSendErrorLogs() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: sendErrorLogsCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(sendErrorLogsCellIdentifier)")
        }
        cell.selectionStyle = .default
        cell.textLabel?.text = "Send Error Logs"

        // Show indicator if enhanced monitoring is enabled
        Task {
            let isEnhanced = await DeviceSpecificErrorMonitor.shared.isEnhancedLoggingEnabled()
            if isEnhanced {
                await MainActor.run {
                    cell.detailTextLabel?.text = "🔍 Enhanced"
                    cell.detailTextLabel?.textColor = .systemGreen
                }
            }
        }

        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func cellForEmailAudiobookLogs() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: emailLogsCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(emailLogsCellIdentifier)")
        }
        cell.selectionStyle = .default
        cell.textLabel?.text = "Email Audiobook Logs"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    #if DEBUG
    @objc func badgeLoggingSwitchDidChange(sender: UISwitch) {
        self.debugSettings.isBadgeLoggingEnabled = sender.isOn
    }

    private func cellForBadgeLogging() -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: badgeLoggingCellIdentifier) else {
            fatalError("Failed to dequeue cell with identifier \(badgeLoggingCellIdentifier)")
        }
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enable Badge Logging"
        cell.accessoryView = createSwitch(
            isOn: self.debugSettings.isBadgeLoggingEnabled,
            action: #selector(badgeLoggingSwitchDidChange)
        )
        return cell
    }

    private func cellForTestHolds() -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: testHoldsCellIdentifier)
        cell.selectionStyle = .default
        cell.textLabel?.text = "Test Holds Configuration"
        cell.textLabel?.adjustsFontSizeToFitWidth = true

        let currentConfig = self.debugSettings.testHoldsConfiguration
        cell.detailTextLabel?.text = currentConfig.displayName
        cell.detailTextLabel?.textColor = currentConfig == .none ? .secondaryLabel : .systemBlue
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    #else
    private func cellForBadgeLogging() -> UITableViewCell {
        return UITableViewCell()
    }

    private func cellForTestHolds() -> UITableViewCell {
        return UITableViewCell()
    }
    #endif

    private func cellForFCMToken() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: fcmTokenCellIdentifier)
        cell.selectionStyle = .default
        cell.textLabel?.text = "FCM Token"
        cell.detailTextLabel?.text = "Loading..."
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 1
        cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
        cell.accessoryType = .none

        Task {
            let token = await NotificationService.shared.currentFCMToken()
            await MainActor.run {
                cell.detailTextLabel?.text = token ?? "No token"
            }
        }
        return cell
    }

    private func copyFCMToken() {
        Task {
            let token = await NotificationService.shared.currentFCMToken()
            await MainActor.run {
                if let token {
                    UIPasteboard.general.string = token
                    let alert = TPPAlertUtils.alert(
                        title: "FCM Token Copied",
                        message: "Token copied to clipboard.\n\n\(token.prefix(20))...\(token.suffix(20))"
                    )
                    self.present(alert, animated: true)
                } else {
                    let alert = TPPAlertUtils.alert(
                        title: "No FCM Token",
                        message: "Push notifications may not be configured. Check that notification permissions are granted."
                    )
                    self.present(alert, animated: true)
                }
            }
        }
    }

    private func cellForTestHoldNotification() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "testHoldNotificationCell")
        cell.selectionStyle = .default
        cell.textLabel?.text = "Send Hold Available"
        cell.detailTextLabel?.text = "Schedules a test notification with delay"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func cellForTestLoanExpiryNotification() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "testLoanExpiryCell")
        cell.selectionStyle = .default
        cell.textLabel?.text = "Send Loan Expiry Warning"
        cell.detailTextLabel?.text = "Schedules a test notification with delay"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
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

    private func scheduleTestNotification(type: TestNotificationType) {
        let alert = UIAlertController(
            title: "Schedule \(type.title)",
            message: "Choose a delay. Background the app before the notification fires to test tap-to-navigate.",
            preferredStyle: .actionSheet
        )

        for delay in [5, 10, 15, 30] {
            alert.addAction(UIAlertAction(title: "\(delay) seconds", style: .default) { [weak self] _ in
                self?.fireTestNotification(type: type, delay: TimeInterval(delay))
            })
        }

        alert.addAction(UIAlertAction(title: "Immediately", style: .default) { [weak self] _ in
            self?.fireTestNotification(type: type, delay: 1)
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            let row = type.categoryIdentifier == HoldNotificationCategoryIdentifier ? 1 : 2
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: row, section: Section.pushNotificationTesting.rawValue))
        }

        present(alert, animated: true)
    }

    private func fireTestNotification(type: TestNotificationType, delay: TimeInterval) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    let alert = TPPAlertUtils.alert(
                        title: "Notifications Disabled",
                        message: "Enable notifications in Settings → Palace to test push notifications."
                    )
                    self?.present(alert, animated: true)
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

            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error {
                        let alert = TPPAlertUtils.alert(title: "Error", message: error.localizedDescription)
                        self?.present(alert, animated: true)
                    } else {
                        let alert = TPPAlertUtils.alert(
                            title: "Notification Scheduled",
                            message: "Firing in \(Int(delay))s. Background the app now to test tap-to-navigate."
                        )
                        self?.present(alert, animated: true)
                    }
                }
            }
        }
    }

    private func cellForErrorSimulation() -> UITableViewCell {
        let currentError = self.debugSettings.simulatedBorrowError

        let cell = UITableViewCell(style: .value1, reuseIdentifier: errorSimulationCellIdentifier)
        cell.selectionStyle = .default
        cell.textLabel?.text = "Simulate Borrow Error"
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.detailTextLabel?.text = currentError.displayName
        cell.detailTextLabel?.textColor = currentError == .none ? .secondaryLabel : .systemOrange
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func cellForSyncFailureSimulation() -> UITableViewCell {
        let currentFailure = self.debugSettings.simulatedSyncFailure

        let cell = UITableViewCell(style: .value1, reuseIdentifier: "syncFailureSimulationCell")
        cell.selectionStyle = .default
        cell.textLabel?.text = "Simulate Sync Failure"
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.detailTextLabel?.text = currentFailure.displayName
        cell.detailTextLabel?.textColor = currentFailure == .none ? .secondaryLabel : .systemRed
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    #if DEBUG
    private func cellForMockBackend() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "mockBackendCell")
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        let service = MockBackendService.shared
        if service.isActive, let scenario = service.currentScenario {
            cell.textLabel?.text = "Mock Backend: \(scenario.displayName)"
            cell.textLabel?.textColor = .systemGreen
            cell.detailTextLabel?.text = "Active — \(scenario.routes.count) routes"
        } else {
            cell.textLabel?.text = "Mock Backend"
            cell.textLabel?.textColor = .label
            cell.detailTextLabel?.text = "Tap to configure"
        }
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    private func cellForPreviewErrorDetails() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "previewErrorDetailsCell")
        cell.selectionStyle = .default
        cell.textLabel?.text = "Preview Error Details View"
        cell.textLabel?.textColor = .systemBlue
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func showPreviewErrorDetails() {
        Task {
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
                let detailVC = ErrorDetailViewController(errorDetail: detail)
                let nav = UINavigationController(rootViewController: detailVC)
                self.present(nav, animated: true)
            }
        }
    }
    #endif

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        self.tableView.deselectRow(at: indexPath, animated: true)

        // F-011 class-of-bug guard
        switch Section(rawValue: indexPath.section) {
        case .dataManagement:
            accountsManager.clearCache()
            ImageCache.shared.clear()
            let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
            self.present(alert, animated: true, completion: nil)

        case .developerTools:
            switch indexPath.row {
            case 0:
                sendErrorLogs()
            default:
                emailAudiobookLogs()
            }

        case .pushNotificationTesting:
            switch indexPath.row {
            case 0: copyFCMToken()
            case 1: scheduleTestNotification(type: .holdAvailable)
            default: scheduleTestNotification(type: .loanExpiry)
            }

        case .badgeTesting:
            #if DEBUG
            if indexPath.row == 1 {
                showTestHoldsPicker()
            }
            #endif

        case .errorSimulation:
            switch indexPath.row {
            case 0:
                showErrorSimulationPicker()
            case 1:
                showSyncFailurePicker()
            default:
                #if DEBUG
                showPreviewErrorDetails()
                #endif
            }

        #if DEBUG
        case .mockBackend:
            showMockBackendPicker()
        case .resetAccountTesting:
            switch indexPath.row {
            case 0: simulateResetAccountStuckState()
            case 1: inspectResetAccountState()
            default: setNextOIDCEphemeralFlagForTesting()
            }
        #endif

        case .librarySettings, .libraryRegistryDebugging, .featurePreviews, nil:
            break
        }
    }

    #if DEBUG
    private func showMockBackendPicker() {
        let hostingController = UIHostingController(rootView: MockBackendPickerView())
        hostingController.title = "Mock Backend"
        navigationController?.pushViewController(hostingController, animated: true)
    }
    #endif

    #if DEBUG
    private func showTestHoldsPicker() {
        let alert = UIAlertController(
            title: "Test Holds Configuration",
            message: "Select a test configuration to verify badge behavior.\n\nNote: This creates mock books with specific availability states. The app will use real data when set to 'None'.",
            preferredStyle: .actionSheet
        )

        for config in DebugSettings.TestHoldsConfiguration.allCases {
            let isSelected = self.debugSettings.testHoldsConfiguration == config
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: config.displayName + checkmark, style: .default) { [weak self] _ in
                self?.debugSettings.testHoldsConfiguration = config
                self?.tableView.reloadData()

                NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
                NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)

                if config != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Test Holds Enabled",
                        message: "Badge should show: \(config.expectedBadgeCount)\n\nGo to the Reservations tab to see the test books. Remember to disable when done testing."
                    )
                    self?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 1, section: Section.badgeTesting.rawValue))
        }

        present(alert, animated: true)
    }
    #endif

    private func showErrorSimulationPicker() {
        let alert = UIAlertController(
            title: "Simulate Borrow Error",
            message: "Select an error type to simulate when borrowing books. The error will appear until you set it back to 'None'.",
            preferredStyle: .actionSheet
        )

        for errorType in DebugSettings.SimulatedBorrowError.allCases {
            let isSelected = self.debugSettings.simulatedBorrowError == errorType
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: errorType.displayName + checkmark, style: .default) { [weak self] _ in
                self?.debugSettings.simulatedBorrowError = errorType
                self?.tableView.reloadData()

                if errorType != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Error Simulation Enabled",
                        message: "'\(errorType.displayName)' will be shown when you try to borrow any book. Remember to disable this when done testing."
                    )
                    self?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: Section.errorSimulation.rawValue))
        }

        present(alert, animated: true)
    }

    private func showSyncFailurePicker() {
        let alert = UIAlertController(
            title: "Simulate Sync Failure",
            message: "Simulates the loans feed sync failing silently \u{2014} the exact scenario reported by users where hold notifications don't convert to checkouts.\n\nEnable, then pull-to-refresh on Holds or switch to foreground.",
            preferredStyle: .actionSheet
        )

        for failureType in DebugSettings.SimulatedSyncFailure.allCases {
            let isSelected = self.debugSettings.simulatedSyncFailure == failureType
            let checkmark = isSelected ? " \u{2713}" : ""

            alert.addAction(UIAlertAction(title: failureType.displayName + checkmark, style: .default) { [weak self] _ in
                self?.debugSettings.simulatedSyncFailure = failureType
                self?.tableView.reloadData()

                if failureType != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Sync Failure Enabled",
                        message: "'\(failureType.displayName)' will be simulated on every sync. Go to Holds and pull to refresh \u{2014} notice how nothing happens and no error is shown.\n\nDisable when done testing."
                    )
                    self?.present(confirmAlert, animated: true)
                }
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 1, section: Section.errorSimulation.rawValue))
        }

        present(alert, animated: true)
    }

    private func sendErrorLogs() {
        Task {
            // Show device ID for support
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
                alert.addAction(UIAlertAction(title: "Preview Logs", style: .default) { _ in
                    self.previewLogs()
                })
                alert.addAction(UIAlertAction(title: "Send Logs", style: .default) { _ in
                    Task {
                        await ErrorLogExporter.shared.sendErrorLogs(from: self)
                    }
                })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

                self.present(alert, animated: true)
            }
        }
    }

    private func previewLogs() {
        Task {
            let loadingAlert = UIAlertController(
                title: "Collecting Logs",
                message: "Please wait...",
                preferredStyle: .alert
            )
            await MainActor.run {
                self.present(loadingAlert, animated: true)
            }

            let logData = await ErrorLogExporter.shared.collectLogsForPreview()

            await MainActor.run {
                loadingAlert.dismiss(animated: true) {
                    let previewVC = LogPreviewViewController(logData: logData)
                    let nav = UINavigationController(rootViewController: previewVC)
                    nav.modalPresentationStyle = .fullScreen
                    previewVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
                        barButtonSystemItem: .done,
                        target: self,
                        action: #selector(self.dismissLogPreview)
                    )
                    self.present(nav, animated: true)
                }
            }
        }
    }

    @objc private func dismissLogPreview() {
        dismiss(animated: true)
    }

    private func emailAudiobookLogs() {
        guard MFMailComposeViewController.canSendMail() else {
            let alert = TPPAlertUtils.alert(title: "Mail Unavailable", message: "Cannot send email. Please configure an email account.")
            self.present(alert, animated: true, completion: nil)
            return
        }

        let mailComposer = MFMailComposeViewController()
        mailComposer.mailComposeDelegate = self
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

        self.present(mailComposer, animated: true, completion: nil)
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        controller.dismiss(animated: true, completion: nil)
    }

    // MARK: - Reset Account Testing (PP-4282 / HelpSpot 17716)
    //
    // Test harness for the patron-self-service Reset Account button. Lets QA
    // and support reproduce the stuck-state condition (so they can verify
    // Reset Account actually unblocks the patron) and inspect post-reset
    // state. All three handlers are #if DEBUG so the section + code never
    // ship to production builds.

    #if DEBUG
    private func cellForResetAccountSimulateStuck() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "resetAccountSimulateStuckCell")
        cell.textLabel?.text = "1. Simulate Stuck State"
        cell.detailTextLabel?.text = "Marks current account as if push-reg silently failed and SAML credentials went stale. Then go tap Reset Account."
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func cellForResetAccountInspect() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "resetAccountInspectCell")
        cell.textLabel?.text = "2. Inspect Account State"
        cell.detailTextLabel?.text = "Shows current values for everything Reset Account touches. Use after Simulate (state should look broken) and after Reset (state should look clean)."
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func cellForResetAccountSetEphemeral() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "resetAccountSetEphemeralCell")
        cell.textLabel?.text = "3. Set One-Shot Ephemeral Flag"
        cell.detailTextLabel?.text = "Manually sets the next-OIDC-session-ephemeral flag without running a full Reset. Lets you verify the OIDC consume path independently."
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// Step 1: programmatically force the patron's app into the broken state
    /// that Reset Account is designed to recover from. Sets the flags +
    /// state Reset Account checks for, but does NOT actually break network
    /// access (so post-Reset sign-in can succeed).
    private func simulateResetAccountStuckState() {
        guard let account = accountsManager.currentAccount else {
            presentResetAccountAlert(title: "No Current Account",
                                     message: "Add and select a library first, then come back here.")
            return
        }

        let user = accountsManager.currentUserAccount

        // 1. Simulate "we think we registered FCM but actually didn't" — the
        //    PP-4275 silent-failure mode that Reset Account heals on next launch.
        account.hasUpdatedToken = true

        // 2. Simulate stale SAML/OIDC session — the credentialsStale state that
        //    triggers the audiobook-OPEN re-auth in PP-4276 and that Reset clears.
        user.markCredentialsStale()

        // 3. ACTUALLY corrupt the bearer token so server-side operations
        //    (borrow, return, sync, fulfillment) start returning 401. Without
        //    this step, the simulation only flips flags and the bearer keeps
        //    working — patrons reported "I can still borrow", which proves
        //    the previous simulation was too soft. Preserves barcode + pin so
        //    the next sign-in flow is the natural credential-prompt path.
        let corruptedToken = "INVALID_SIMULATED_STUCK_STATE_BEARER_TOKEN"
        let pastDate = Date(timeIntervalSinceNow: -3600)
        user.setAuthToken(
            corruptedToken,
            barcode: user.barcode,
            pin: user.PIN,
            expirationDate: pastDate
        )

        // 4. Pre-clear the one-shot ephemeral flag so we can confirm Reset
        //    (a) sets it AND (b) the OIDC path consumes-and-clears it.
        //    (No-op for non-OIDC libraries — see step 3 cell.)
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
                """
        )
    }

    /// Step 2: dump the state Reset Account touches. Lets QA confirm
    /// before/after.
    private func inspectResetAccountState() {
        guard let account = accountsManager.currentAccount else {
            presentResetAccountAlert(title: "No Current Account",
                                     message: "Add and select a library first.")
            return
        }
        let user = accountsManager.currentUserAccount

        // We use UserDefaults.bool here rather than the consume helper so
        // inspecting doesn't side-effect-clear the flag.
        let ephemeralFlagSet = UserDefaults.standard.bool(forKey: TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey)

        let webDataStore = WKWebsiteDataStore.default()
        webDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            DispatchQueue.main.async {
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
                self?.presentResetAccountAlert(
                    title: "Account State",
                    message: lines.joined(separator: "\n")
                )
            }
        }
    }

    /// Step 3: directly set the one-shot flag (without running a full Reset).
    /// Use this to test the OIDC consume path in isolation — sign in to an
    /// OIDC library and confirm the ASWebAuthenticationSession was created
    /// with prefersEphemeralWebBrowserSession = true (visible if the patron
    /// is forced through a real IdP login instead of silent SSO).
    private func setNextOIDCEphemeralFlagForTesting() {
        UserDefaults.standard.set(true, forKey: TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey)
        presentResetAccountAlert(
            title: "Ephemeral Flag Set",
            message: """
                The next OIDC ASWebAuthenticationSession will be created with prefersEphemeralWebBrowserSession = true.

                To verify: sign out of an OIDC library, then sign back in. You should be forced through a real IdP authentication (not a silent SSO redirect).

                After that one session, the flag self-clears and silent SSO is restored.
                """
        )
    }

    private func presentResetAccountAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    #endif
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
