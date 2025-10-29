import MessageUI

@objcMembers
class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, MFMailComposeViewControllerDelegate {
  
  weak var tableView: UITableView!
  var loadingView: UIView?
  
  enum Section: Int, CaseIterable {
    case librarySettings = 0
    case libraryRegistryDebugging
    case dataManagement
    case performanceMonitoring
    case developerTools
  }
  
  private let betaLibraryCellIdentifier = "betaLibraryCell"
  private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
  private let clearCacheCellIdentifier = "clearCacheCell"
  private let emailLogsCellIdentifier = "emailLogsCell"
  private let sendErrorLogsCellIdentifier = "sendErrorLogsCell"
  private let actorMonitoringCellIdentifier = "actorMonitoringCell"
  private let actorHealthReportCellIdentifier = "actorHealthReportCell"
  
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
  
  @objc func actorMonitoringSwitchDidChange(sender: UISwitch) {
    Task {
      await ActorHealthMonitor.shared.setEnabled(sender.isOn)
      
      let message = sender.isOn
        ? "Actor health monitoring enabled. Slow operations will be logged."
        : "Actor health monitoring disabled. No performance overhead."
      
      await MainActor.run {
        let alert = TPPAlertUtils.alert(title: "Actor Monitoring", message: message)
        self.present(alert, animated: true)
      }
    }
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
    self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: actorMonitoringCellIdentifier)
    self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: actorHealthReportCellIdentifier)
  }
  
  // MARK:- UITableViewDataSource
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section)! {
    case .librarySettings: return 2
    case .performanceMonitoring: return 2
    case .developerTools: return 2
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
    case .performanceMonitoring:
      switch indexPath.row {
      case 0: return cellForActorMonitoring()
      default: return cellForActorHealthReport()
      }
    case .developerTools:
      switch indexPath.row {
      case 0: return cellForSendErrorLogs()
      default: return cellForEmailAudiobookLogs()
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
    case .performanceMonitoring:
      return "Performance Monitoring"
    case .developerTools:
      return "Developer Tools"
    }
  }
  
  func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    switch Section(rawValue: section)! {
    case .performanceMonitoring:
      #if DEBUG
      return "Actor monitoring enabled in DEBUG builds. Tracks slow operations (>5s) and critical delays (>10s)."
      #else
      return "Actor monitoring disabled in RELEASE builds by default for performance."
      #endif
    default:
      return nil
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
  
  private func cellForActorMonitoring() -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: actorMonitoringCellIdentifier)!
    cell.selectionStyle = .none
    cell.textLabel?.text = "Enable Actor Health Monitoring"
    cell.textLabel?.adjustsFontSizeToFitWidth = true
    cell.textLabel?.minimumScaleFactor = 0.7
    
    // Get current state asynchronously
    let switchControl = UISwitch()
    switchControl.addTarget(self, action: #selector(actorMonitoringSwitchDidChange), for: .valueChanged)
    
    Task {
      let isEnabled = await ActorHealthMonitor.shared.getEnabled()
      await MainActor.run {
        switchControl.isOn = isEnabled
      }
    }
    
    cell.accessoryView = switchControl
    return cell
  }
  
  private func cellForActorHealthReport() -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: actorHealthReportCellIdentifier)!
    cell.selectionStyle = .default
    cell.textLabel?.text = "View Actor Health Report"
    cell.accessoryType = .disclosureIndicator
    return cell
  }
  
  // MARK:- UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    self.tableView.deselectRow(at: indexPath, animated: true)
    
    if Section(rawValue: indexPath.section) == .dataManagement {
      AccountsManager.shared.clearCache()
      ImageCache.shared.clear()
      let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
      self.present(alert, animated: true, completion: nil)
    } else if Section(rawValue: indexPath.section) == .performanceMonitoring {
      switch indexPath.row {
      case 1:
        showActorHealthReport()
      default:
        break
      }
    } else if Section(rawValue: indexPath.section) == .developerTools {
      switch indexPath.row {
      case 0:
        sendErrorLogs()
      default:
        emailAudiobookLogs()
      }
    }
  }
  
  private func sendErrorLogs() {
    Task {
      await ErrorLogExporter.shared.sendErrorLogs(from: self)
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
  
  private func showActorHealthReport() {
    Task {
      let report = await ActorHealthMonitor.shared.getHealthReport()
      let isEnabled = await ActorHealthMonitor.shared.getEnabled()
      
      let activeCount = report["activeOperationCount"] as? Int ?? 0
      let slowCount = report["slowOperationCount"] as? Int ?? 0
      let criticalCount = report["criticalOperationCount"] as? Int ?? 0
      
      var message = """
      Monitoring: \(isEnabled ? "✅ Enabled" : "⚠️ Disabled")
      
      Active Operations: \(activeCount)
      Slow Operations (>5s): \(slowCount)
      Critical Operations (>10s): \(criticalCount)
      """
      
      if let slowOps = report["slowOperations"] as? [[String: Any]], !slowOps.isEmpty {
        message += "\n\n--- Slow Operations ---"
        for op in slowOps {
          let name = op["name"] as? String ?? "unknown"
          let actorType = op["actorType"] as? String ?? "unknown"
          let duration = op["duration"] as? TimeInterval ?? 0
          message += "\n• \(name)"
          message += "\n  Actor: \(actorType)"
          message += "\n  Duration: \(String(format: "%.2f", duration))s"
        }
      } else if isEnabled {
        message += "\n\n✅ All operations running smoothly!"
      } else {
        message += "\n\nℹ️ Enable monitoring to track actor performance."
      }
      
      await MainActor.run {
        let alert = UIAlertController(
          title: "Actor Health Report",
          message: message,
          preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        
        // Add "Copy Report" action for debugging
        alert.addAction(UIAlertAction(title: "Copy Report", style: .default) { _ in
          UIPasteboard.general.string = message
          Log.info(#file, "Actor health report copied to clipboard")
        })
        
        self.present(alert, animated: true)
      }
    }
  }
  
  func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
    controller.dismiss(animated: true, completion: nil)
  }
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
