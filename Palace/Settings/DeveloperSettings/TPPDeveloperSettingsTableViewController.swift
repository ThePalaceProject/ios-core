import MessageUI

@objcMembers
class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, MFMailComposeViewControllerDelegate {

    weak var tableView: UITableView!
    var loadingView: UIView?

    enum Section: Int, CaseIterable {
        case librarySettings = 0
        case libraryRegistryDebugging
        case dataManagement
        case developerTools
        case featurePreviews
        case badgeTesting
        case errorSimulation
    }

    private let betaLibraryCellIdentifier = "betaLibraryCell"
    private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
    private let clearCacheCellIdentifier = "clearCacheCell"
    private let emailLogsCellIdentifier = "emailLogsCell"
    private let sendErrorLogsCellIdentifier = "sendErrorLogsCell"
    private let errorSimulationCellIdentifier = "errorSimulationCell"
    private let incrementalSpeedSliderCellIdentifier = "incrementalSpeedSliderCell"
    private let badgeLoggingCellIdentifier = "badgeLoggingCell"
    private let testHoldsCellIdentifier = "testHoldsCell"

    private var pushNotificationsStatus = false

    required init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func librarySwitchDidChange(sender: UISwitch!) {
        TPPSettings.shared.useBetaLibraries = sender.isOn
    }

    func enterLCPPassphraseSwitchDidChange(sender: UISwitch) {
        TPPSettings.shared.enterLCPPassphraseManually = sender.isOn
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
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: incrementalSpeedSliderCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: badgeLoggingCellIdentifier)
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: testHoldsCellIdentifier)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .librarySettings: return 2
        case .developerTools: return 2
        case .featurePreviews: return 1
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
        default: return 1
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
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
        case .featurePreviews:
            return cellForIncrementalSpeedSlider()
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
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .librarySettings:
            return "Library Settings"
        case .libraryRegistryDebugging:
            return "Library Registry Debugging"
        case .dataManagement:
            return "Data Management"
        case .developerTools:
            return "Developer Tools"
        case .featurePreviews:
            return "Feature Previews"
        case .badgeTesting:
            #if DEBUG
            return "Badge Testing"
            #else
            return nil
            #endif
        case .errorSimulation:
            return "Error Simulation (Testing)"
        }
    }

    private func createSwitch(isOn: Bool, action: Selector) -> UISwitch {
        let switchControl = UISwitch()
        switchControl.isOn = isOn
        switchControl.addTarget(self, action: action, for: .valueChanged)
        return switchControl
    }

    private func cellForBetaLibraries() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: betaLibraryCellIdentifier)!
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enable Hidden Libraries"
        cell.accessoryView = createSwitch(isOn: TPPSettings.shared.useBetaLibraries, action: #selector(librarySwitchDidChange))
        return cell
    }

    private func cellForLCPPassphrase() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: lcpPassphraseCellIdentifier)!
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enter LCP Passphrase Manually"
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.textLabel?.minimumScaleFactor = 0.5
        cell.accessoryView = createSwitch(isOn: TPPSettings.shared.enterLCPPassphraseManually, action: #selector(enterLCPPassphraseSwitchDidChange))
        return cell
    }

    private func cellForCustomRegsitry() -> UITableViewCell {
        let cell = TPPRegistryDebuggingCell()
        cell.delegate = self
        return cell
    }

    private func cellForClearCache() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: clearCacheCellIdentifier)!
        cell.selectionStyle = .none
        cell.textLabel?.text = "Clear Cached Data"
        return cell
    }

    private func cellForSendErrorLogs() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: sendErrorLogsCellIdentifier)!
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
        let cell = tableView.dequeueReusableCell(withIdentifier: emailLogsCellIdentifier)!
        cell.selectionStyle = .default
        cell.textLabel?.text = "Email Audiobook Logs"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    #if DEBUG
    @objc func incrementalSpeedSliderSwitchDidChange(sender: UISwitch) {
        DebugSettings.shared.isIncrementalSpeedSliderEnabled = sender.isOn
    }

    private func cellForIncrementalSpeedSlider() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: incrementalSpeedSliderCellIdentifier)!
        cell.selectionStyle = .none
        cell.textLabel?.text = "Incremental Speed Slider"
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.accessoryView = createSwitch(
            isOn: DebugSettings.shared.isIncrementalSpeedSliderEnabled,
            action: #selector(incrementalSpeedSliderSwitchDidChange)
        )
        return cell
    }

    @objc func badgeLoggingSwitchDidChange(sender: UISwitch) {
        DebugSettings.shared.isBadgeLoggingEnabled = sender.isOn
    }

    private func cellForBadgeLogging() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: badgeLoggingCellIdentifier)!
        cell.selectionStyle = .none
        cell.textLabel?.text = "Enable Badge Logging"
        cell.accessoryView = createSwitch(
            isOn: DebugSettings.shared.isBadgeLoggingEnabled,
            action: #selector(badgeLoggingSwitchDidChange)
        )
        return cell
    }

    private func cellForTestHolds() -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: testHoldsCellIdentifier)
        cell.selectionStyle = .default
        cell.textLabel?.text = "Test Holds Configuration"
        cell.textLabel?.adjustsFontSizeToFitWidth = true

        let currentConfig = DebugSettings.shared.testHoldsConfiguration
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

    private func cellForErrorSimulation() -> UITableViewCell {
        let currentError = DebugSettings.shared.simulatedBorrowError

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
        let currentFailure = DebugSettings.shared.simulatedSyncFailure

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

        switch Section(rawValue: indexPath.section) {
        case .dataManagement:
            AccountsManager.shared.clearCache()
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

        default:
            break
        }
    }

    #if DEBUG
    private func showTestHoldsPicker() {
        let alert = UIAlertController(
            title: "Test Holds Configuration",
            message: "Select a test configuration to verify badge behavior.\n\nNote: This creates mock books with specific availability states. The app will use real data when set to 'None'.",
            preferredStyle: .actionSheet
        )

        for config in DebugSettings.TestHoldsConfiguration.allCases {
            let isSelected = DebugSettings.shared.testHoldsConfiguration == config
            let checkmark = isSelected ? " ✓" : ""
            let expectedBadge = config.expectedBadgeCount >= 0 ? " (badge=\(config.expectedBadgeCount))" : ""

            alert.addAction(UIAlertAction(title: config.displayName + checkmark, style: .default) { [weak self] _ in
                DebugSettings.shared.testHoldsConfiguration = config
                self?.tableView.reloadData()

                NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
                NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil)

                if config != .none {
                    let confirmAlert = TPPAlertUtils.alert(
                        title: "Test Holds Enabled",
                        message: "Badge should show: \(config.expectedBadgeCount)\n\nGo to the Holds tab to see the test books. Remember to disable when done testing."
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
            let isSelected = DebugSettings.shared.simulatedBorrowError == errorType
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: errorType.displayName + checkmark, style: .default) { [weak self] _ in
                DebugSettings.shared.simulatedBorrowError = errorType
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
            let isSelected = DebugSettings.shared.simulatedSyncFailure == failureType
            let checkmark = isSelected ? " ✓" : ""

            alert.addAction(UIAlertAction(title: failureType.displayName + checkmark, style: .default) { [weak self] _ in
                DebugSettings.shared.simulatedSyncFailure = failureType
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
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
