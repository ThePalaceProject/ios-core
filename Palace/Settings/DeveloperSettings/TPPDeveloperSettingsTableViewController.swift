import Foundation

/// UITableView to display or add library accounts that the user
/// can then log in and adjust settings after selecting Accounts.
@objcMembers class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
  weak var tableView: UITableView!
  var loadingView: UIView?

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

  func encryptedPDFReaderSwitchDidChange(sender: UISwitch) {
    TPPSettings.shared.useEncryptedPDFReader = sender.isOn
  }
  // MARK:- UIViewController
  
  override func loadView() {
    self.view = UITableView(frame: CGRect.zero, style: .grouped)
    self.tableView = self.view as? UITableView
    self.tableView.delegate = self
    self.tableView.dataSource = self
    
    self.title = NSLocalizedString("Testing", comment: "Developer Settings")
    self.view.backgroundColor = TPPConfiguration.backgroundColor()
  }
  
  // MARK:- UITableViewDataSource
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 2
    default: return 1
    }
  }
  
  func numberOfSections(in tableView: UITableView) -> Int {
    return 3
  }
  
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch indexPath.section {
    case 0:
      switch indexPath.row {
      case 0: return cellForBetaLibraries()
      default: return cellForEncryptedPDFReader()
      }
    case 1: return cellForCustomRegsitry()
    default: return cellForClearCache()
    }
  }
  
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0:
      return "Library Settings"
    case 1:
      return "Library Registry Debugging"
    default:
      return "Data Management"
    }
  }
  
  private func cellForBetaLibraries() -> UITableViewCell {
    let cell = UITableViewCell(style: UITableViewCell.CellStyle.default, reuseIdentifier: "betaLibraryCell")
    cell.selectionStyle = .none
    cell.textLabel?.text = "Enable Hidden Libraries"
    let betaLibrarySwitch = UISwitch()
    betaLibrarySwitch.setOn(TPPSettings.shared.useBetaLibraries, animated: false)
    betaLibrarySwitch.addTarget(self, action:#selector(librarySwitchDidChange), for:.valueChanged)
    cell.accessoryView = betaLibrarySwitch
    return cell
  }
  
  private func cellForEncryptedPDFReader() -> UITableViewCell {
    let cell = UITableViewCell(style: UITableViewCell.CellStyle.default, reuseIdentifier: "encryptedPDFReaderCell")
    cell.selectionStyle = .none
    cell.textLabel?.text = "Enable Beta PDF Reader"
    let betaLibrarySwitch = UISwitch()
    betaLibrarySwitch.setOn(TPPSettings.shared.useEncryptedPDFReader, animated: false)
    betaLibrarySwitch.addTarget(self, action:#selector(encryptedPDFReaderSwitchDidChange), for: .valueChanged)
    cell.accessoryView = betaLibrarySwitch
    return cell
  }
  
  private func cellForCustomRegsitry() -> UITableViewCell {
    let cell = TPPRegistryDebuggingCell()
    cell.delegate = self
    return cell
  }
  
  private func cellForClearCache() -> UITableViewCell {
    let cell = UITableViewCell(style: UITableViewCell.CellStyle.default, reuseIdentifier: "clearCacheCell")
    cell.selectionStyle = .none
    cell.textLabel?.text = "Clear Cached Data"
    return cell
  }
  
  // MARK:- UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    self.tableView.deselectRow(at: indexPath, animated: true)
    
    if indexPath.section == 3 {
      AccountsManager.shared.clearCache()
      let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
      self.present(alert, animated: true, completion: nil)
    }
  }
  
  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    return UITableView.automaticDimension
  }
  
  func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
    return 80
  }
  
  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    return false
  }
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
