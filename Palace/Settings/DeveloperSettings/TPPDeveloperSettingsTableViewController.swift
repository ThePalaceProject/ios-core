import MessageUI

// MARK: - TPPDeveloperSettingsTableViewController

@objcMembers
class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource,
  MFMailComposeViewControllerDelegate
{
  weak var tableView: UITableView!
  var loadingView: UIView?

  enum Section: Int, CaseIterable {
    case librarySettings = 0
    case libraryRegistryDebugging
    case dataManagement
    case developerTools
  }

  private let betaLibraryCellIdentifier = "betaLibraryCell"
  private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
  private let clearCacheCellIdentifier = "clearCacheCell"
  private let emailLogsCellIdentifier = "emailLogsCell"

  private var pushNotificationsStatus = false

  required init() {
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
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
    view = UITableView(frame: CGRect.zero, style: .grouped)
    tableView = view as? UITableView
    tableView.delegate = self
    tableView.dataSource = self

    title = Strings.TPPDeveloperSettingsTableViewController.developerSettingsTitle
    view.backgroundColor = TPPConfiguration.backgroundColor()

    tableView.register(UITableViewCell.self, forCellReuseIdentifier: betaLibraryCellIdentifier)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: lcpPassphraseCellIdentifier)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: clearCacheCellIdentifier)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: emailLogsCellIdentifier)
  }

  // MARK: - UITableViewDataSource

  func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section)! {
    case .librarySettings: 2
    case .developerTools: 1
    default: 1
    }
  }

  func numberOfSections(in _: UITableView) -> Int {
    Section.allCases.count
  }

  func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch Section(rawValue: indexPath.section)! {
    case .librarySettings:
      switch indexPath.row {
      case 0: cellForBetaLibraries()
      default: cellForLCPPassphrase()
      }
    case .libraryRegistryDebugging: cellForCustomRegsitry()
    case .dataManagement: cellForClearCache()
    case .developerTools: cellForEmailLogs()
    }
  }

  func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch Section(rawValue: section)! {
    case .librarySettings:
      "Library Settings"
    case .libraryRegistryDebugging:
      "Library Registry Debugging"
    case .dataManagement:
      "Data Management"
    case .developerTools:
      "Developer Tools"
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
    cell.accessoryView = createSwitch(
      isOn: TPPSettings.shared.useBetaLibraries,
      action: #selector(librarySwitchDidChange)
    )
    return cell
  }

  private func cellForLCPPassphrase() -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: lcpPassphraseCellIdentifier)!
    cell.selectionStyle = .none
    cell.textLabel?.text = "Enter LCP Passphrase Manually"
    cell.textLabel?.adjustsFontSizeToFitWidth = true
    cell.textLabel?.minimumScaleFactor = 0.5
    cell.accessoryView = createSwitch(
      isOn: TPPSettings.shared.enterLCPPassphraseManually,
      action: #selector(enterLCPPassphraseSwitchDidChange)
    )
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

  private func cellForEmailLogs() -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: emailLogsCellIdentifier)!
    cell.selectionStyle = .none
    cell.textLabel?.text = "Email Logs"
    return cell
  }

  // MARK: - UITableViewDelegate

  func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    if Section(rawValue: indexPath.section) == .dataManagement {
      AccountsManager.shared.clearCache()
      ImageCache.shared.clear()
      let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
      present(alert, animated: true, completion: nil)
    } else if Section(rawValue: indexPath.section) == .developerTools {
      emailLogs()
    }
  }

  private func emailLogs() {
    guard MFMailComposeViewController.canSendMail() else {
      let alert = TPPAlertUtils.alert(
        title: "Mail Unavailable",
        message: "Cannot send email. Please configure an email account."
      )
      present(alert, animated: true, completion: nil)
      return
    }

    let mailComposer = MFMailComposeViewController()
    mailComposer.mailComposeDelegate = self
    mailComposer.setSubject("Audiobook Logs")
    mailComposer.setToRecipients(["maurice.carrier@outlook.com"])
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

    present(mailComposer, animated: true, completion: nil)
  }

  func mailComposeController(
    _ controller: MFMailComposeViewController,
    didFinishWith _: MFMailComposeResult,
    error _: Error?
  ) {
    controller.dismiss(animated: true, completion: nil)
  }
}

// MARK: TPPRegistryDebugger

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
