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
    #if DEBUG
    case debugTesting
    #endif
  }
  
  private let betaLibraryCellIdentifier = "betaLibraryCell"
  private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
  private let clearCacheCellIdentifier = "clearCacheCell"
  private let emailLogsCellIdentifier = "emailLogsCell"
  private let sendErrorLogsCellIdentifier = "sendErrorLogsCell"
  
  private var pushNotificationsStatus = false
  
  required init() {
    super.init(nibName: nil, bundle: nil)
  }
  
  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  @objc func librarySwitchDidChange(sender: UISwitch!) {
    TPPSettings.shared.useBetaLibraries = sender.isOn
  }
  
  @objc func enterLCPPassphraseSwitchDidChange(sender: UISwitch) {
    TPPSettings.shared.enterLCPPassphraseManually = sender.isOn
  }
  
  // MARK:- UIViewController
  
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
  }
  
  // MARK:- UITableViewDataSource
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section)! {
    case .librarySettings: return 2
    case .developerTools: return 2
    #if DEBUG
    case .debugTesting: return 1
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
    #if DEBUG
    case .debugTesting: return cellForDebugErrorTriggers()
    #endif
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
    #if DEBUG
    case .debugTesting:
      return "🧪 Debug Testing"
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
  private func cellForDebugErrorTriggers() -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    cell.selectionStyle = .default
    cell.textLabel?.text = "🧪 Trigger Test Errors"
    cell.accessoryType = .disclosureIndicator
    return cell
  }
  #endif
  
  // MARK:- UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    self.tableView.deselectRow(at: indexPath, animated: true)
    
    if Section(rawValue: indexPath.section) == .dataManagement {
      AccountsManager.shared.clearCache()
      ImageCache.shared.clear()
      let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
      self.present(alert, animated: true, completion: nil)
    } else if Section(rawValue: indexPath.section) == .developerTools {
      switch indexPath.row {
      case 0:
        sendErrorLogs()
      default:
        emailAudiobookLogs()
      }
    }
    #if DEBUG
    if Section(rawValue: indexPath.section) == .debugTesting {
      showDebugErrorTriggers()
    }
    #endif
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
  
  #if DEBUG
  private func showDebugErrorTriggers() {
    let alert = UIAlertController(
      title: "🧪 Debug Error Triggers",
      message: "Trigger test errors to verify enhanced logging is working.",
      preferredStyle: .actionSheet
    )
    
    alert.addAction(UIAlertAction(title: "Download Error", style: .default) { _ in
      DebugErrorTriggers.triggerDownloadError()
      let confirmAlert = TPPAlertUtils.alert(
        title: "✅ Triggered",
        message: "Download error triggered! Check console and Firebase."
      )
      self.present(confirmAlert, animated: true)
    })
    
    alert.addAction(UIAlertAction(title: "Network Error", style: .default) { _ in
      DebugErrorTriggers.triggerNetworkError()
      let confirmAlert = TPPAlertUtils.alert(
        title: "✅ Triggered",
        message: "Network error triggered! Check console and Firebase."
      )
      self.present(confirmAlert, animated: true)
    })
    
    alert.addAction(UIAlertAction(title: "Generic Error", style: .default) { _ in
      DebugErrorTriggers.triggerGenericError()
      let confirmAlert = TPPAlertUtils.alert(
        title: "✅ Triggered",
        message: "Generic error triggered! Check console and Firebase."
      )
      self.present(confirmAlert, animated: true)
    })
    
    alert.addAction(UIAlertAction(title: "Multiple Errors", style: .default) { _ in
      DebugErrorTriggers.triggerMultipleErrors()
      let confirmAlert = TPPAlertUtils.alert(
        title: "✅ Triggered",
        message: "Multiple errors triggered! Check console and Firebase."
      )
      self.present(confirmAlert, animated: true)
    })
    
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    
    present(alert, animated: true)
  }
  #endif
  
  func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
    controller.dismiss(animated: true, completion: nil)
  }
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
