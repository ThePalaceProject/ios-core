/// UITableView to display or add library accounts that the user
/// can then log in and adjust settings after selecting Accounts.
@objcMembers class TPPSettingsAccountsTableViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, TPPLoadingViewController {
  
  enum LoadState {
    case loading
    case failure
    case success
  }
  
  weak var tableView: UITableView!
  var reloadView: TPPReloadView!
  var spinner: UIActivityIndicatorView!
  var loadingView: UIView?
  
  fileprivate var accounts: [Account] {
    didSet {
      //update TPPSettings
    }
  }
  fileprivate var libraryAccounts: [Account]
  fileprivate var userAddedSecondaryAccounts: [Account]!
  fileprivate let manager: AccountsManager
  
  required init(accounts: [Account]) {
    self.accounts = accounts
    self.manager = AccountsManager.shared
    self.libraryAccounts = manager.accounts()
    
    super.init(nibName:nil, bundle:nil)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  @available(*, unavailable)
  required init(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  // MARK: UIViewController
  
  override func loadView() {
    self.view = UITableView(frame: CGRect.zero, style: .grouped)
    self.tableView = self.view as? UITableView
    self.tableView.delegate = self
    self.tableView.dataSource = self
    self.tableView.register(TPPAccountListCell.self, forCellReuseIdentifier: TPPAccountListCell.reuseIdentifier)

    spinner = UIActivityIndicatorView(style: .medium)
    view.addSubview(spinner)
    
    reloadView = TPPReloadView()
    reloadView.handler = { [weak self] in
      guard let self = self else {
        return
      }
      self.reloadAccounts()
    }
    view.addSubview(reloadView)
    
    // cleanup accounts, remove demo account or accounts not supported through accounts.json // will be refactored when implementing librsry registry
    var accountsToRemove = [String]()
    
    for account in accounts {
      if (AccountsManager.shared.account(account.uuid) == nil) {
        accountsToRemove.append(account.uuid)
      }
    }
    
    for remove in accountsToRemove {
      accounts = accounts.filter { $0.uuid == remove }
    }

    self.userAddedSecondaryAccounts = accounts.filter { $0.uuid != AccountsManager.shared.currentAccount?.uuid }

    updateSettingsAccountList()
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(reloadAfterAccountChange),
                                           name: NSNotification.Name.TPPCurrentAccountDidChange,
                                           object: nil)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(catalogChangeHandler),
                                           name: NSNotification.Name.TPPCatalogDidLoad,
                                           object: nil)
    
    self.libraryAccounts = manager.accounts()
    updateNavBar()
  }
  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    spinner.centerInSuperview(withOffset: tableView.contentOffset)
    reloadView.centerInSuperview(withOffset: tableView.contentOffset)
  }
  
  // MARK: -
  
  func showLoadingUI(loadState: LoadState) {
    switch loadState {
    case .loading:
      spinner.isHidden = false
      spinner.startAnimating()
      reloadView.isHidden = true
      view.bringSubviewToFront(spinner)
    case .failure:
      spinner.stopAnimating()
      reloadView.isHidden = false
      view.bringSubviewToFront(reloadView)
    case .success:
      spinner.stopAnimating()
      reloadView.isHidden = true
    }
  }
  
  func reloadAccounts() {
    showLoadingUI(loadState: .loading)
    
    manager.updateAccountSet { [weak self] success in
      TPPMainThreadRun.asyncIfNeeded { [weak self] in
        guard let self = self else {
          return
        }
        if success {
          self.showLoadingUI(loadState: .success)
        } else {
          self.showLoadingUI(loadState: .failure)
          TPPErrorLogger.logError(withCode: .apiCall,
                                  summary: "Accounts list failed to load")
        }
      }
    }
  }
  
  func reloadAfterAccountChange() {
    accounts = TPPSettings.shared.settingsAccountsList
    self.userAddedSecondaryAccounts = accounts.filter { $0.uuid != manager.currentAccount?.uuid }
    DispatchQueue.main.async {
      self.tableView.reloadData()
    }
  }
  
  func catalogChangeHandler() {
    self.libraryAccounts = AccountsManager.shared.accounts()
    DispatchQueue.main.async {
      self.updateNavBar()
    }
  }
  
  private func updateNavBar() {
    var enable = self.userAddedSecondaryAccounts.count + 1 < self.libraryAccounts.count
    
    if TPPSettings.shared.customLibraryRegistryServer != nil {
      enable = self.userAddedSecondaryAccounts.count < self.libraryAccounts.count
    }
    
    self.navigationItem.rightBarButtonItem?.isEnabled = enable
  }
  
  private func updateList(withAccount account: Account) {
    if userAddedSecondaryAccounts.filter({ $0.uuid == account.uuid }).isEmpty {
      userAddedSecondaryAccounts.append(account)
    }
  
    updateSettingsAccountList()
    // Return from search screen to the list of libraries
    navigationController?.popViewController(animated: false)
    // Switch to the selected library
    AccountsManager.shared.currentAccount = account
    self.tableView.reloadData()
  
    let catalog = TPPRootTabBarController.shared()?.viewControllers?.first as? TPPCatalogNavigationController
    catalog?.updateFeedAndRegistryOnAccountChange()
    self.tabBarController?.selectedIndex = 0
    (navigationController?.parent as? UINavigationController)?.popToRootViewController(animated: false)
  }
  
  @objc func addAccount() {
    let listVC = TPPAccountList { [weak self] account in
      if account.details != nil {
        self?.updateList(withAccount: account)
      } else {
        self?.authenticateAccount(account) {
          self?.updateList(withAccount: account)
        }
        self?.libraryAccounts = AccountsManager.shared.accounts()
      }
    }
    navigationController?.pushViewController(listVC, animated: true)
  }
  
  private func authenticateAccount(_ account: Account, completion: @escaping () -> Void) {
    startLoading()
    account.loadAuthenticationDocument { [weak self] success in
      DispatchQueue.main.async {
        self?.stopLoading()
        guard success else {
          self?.showLoadingFailureAlert()
          return
        }
        
        completion()
      }
    }
  }
  
  private func showLoadingFailureAlert() {
    let alert = TPPAlertUtils.alert(title:nil, message:"We can’t get your library right now. Please close and reopen the app to try again.", style: .cancel)
    present(alert, animated: true, completion: nil)
  }
  
  private func updateSettingsAccountList() {
    guard let uuid = manager.currentAccount?.uuid else {
      showLoadingUI(loadState: .failure)
      return
    }
    showLoadingUI(loadState: .success)
    var array = userAddedSecondaryAccounts!.map { $0.uuid }
    array.append(uuid)
    TPPSettings.shared.settingsAccountIdsList = array
  }
  
  // MARK: UITableViewDataSource
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    
    if section == 0 {
      return self.manager.currentAccount != nil ? 1 : 0
    }
    
    return userAddedSecondaryAccounts.count
  }
  
  func numberOfSections(in tableView: UITableView) -> Int {
    return 2
  }
  
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let account = self.manager.currentAccount,  let cell = tableView.dequeueReusableCell(withIdentifier: TPPAccountListCell.reuseIdentifier, for: indexPath) as? TPPAccountListCell else {
      // Should never happen, but better than crashing
      return UITableViewCell()
    }
    
    if (indexPath.section == 0) {
      cell.configure(for: account)
    } else {
      // The app crashes here when we switch registry accounts
      if indexPath.row < userAddedSecondaryAccounts.count {
        cell.configure(for: userAddedSecondaryAccounts[indexPath.row])
      }
    }
    
    return cell
  }

  // MARK: UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    var account: Account?
    if (indexPath.section == 0) {
      account = self.manager.currentAccount
    } else {
      account = userAddedSecondaryAccounts[indexPath.row]
    }
    
    let vc = TPPSettingsAccountDetailViewController(libraryAccountID: account?.uuid ?? "")
    self.tableView.deselectRow(at: indexPath, animated: true)
    self.navigationController?.pushViewController(vc, animated: true)
  }
  
  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    return UITableView.automaticDimension
  }
  
  func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
    return 80
  }
  
  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    return indexPath.section != 0
  }
  
  func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
    if editingStyle == .delete {
      userAddedSecondaryAccounts.remove(at: indexPath.row)
      tableView.deleteRows(at: [indexPath], with: .fade)
      updateSettingsAccountList()
      updateNavBar()
      self.tableView.reloadData()
    }
  }
}
