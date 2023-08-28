import Foundation

/// UITableView to display or add library accounts that the user
/// can then log in and adjust settings after selecting Accounts.
@objcMembers class TPPDeveloperSettingsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
  weak var tableView: UITableView!
  var loadingView: UIView?

  enum Section: Int, CaseIterable {
    case librarySettings = 0
    case libraryRegistryDebugging
    case dataManagement
  }
  
  private let betaLibraryCellIdentifier = "betaLibraryCell"
  private let lcpPassphraseCellIdentifier = "lcpPassphraseCell"
  private let clearCacheCellIdentifier = "clearCacheCell"
  
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
  }
  
  // MARK:- UITableViewDataSource
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section)! {
    case .librarySettings: return 2
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
  
  // MARK:- UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    self.tableView.deselectRow(at: indexPath, animated: true)
    
    if Section(rawValue: indexPath.section) == .dataManagement {
      AccountsManager.shared.clearCache()
      let alert = TPPAlertUtils.alert(title: "Data Management", message: "Cache Cleared")
      self.present(alert, animated: true, completion: nil)
    }
  }
  
  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    UITableView.automaticDimension
  }
  
  func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
    80
  }
  
  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    false
  }
}

extension TPPDeveloperSettingsTableViewController: TPPRegistryDebugger {}
