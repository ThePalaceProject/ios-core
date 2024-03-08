import UIKit

/// Advanced Menu in Settings
@objcMembers class TPPSettingsAdvancedViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  typealias DisplayStrings = Strings.TPPSettingsAdvancedViewController

  var account: Account

  init(account id: String) {
    self.account = AccountsManager.shared.account(id)!
    super.init(nibName: nil, bundle: nil)
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    title = DisplayStrings.advanced
    
    let tableView = UITableView.init(frame: .zero, style: .grouped)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.backgroundColor = TPPConfiguration.backgroundColor()
    self.view.addSubview(tableView)
    tableView.autoPinEdgesToSuperviewEdges()
  }
  
  // MARK: - UITableViewDelegate
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if (indexPath.row == 0) {

      let cell = tableView.cellForRow(at: indexPath)
      cell?.setSelected(false, animated: true)
      
      let message = String.localizedStringWithFormat(NSLocalizedString("Selecting \"Delete\" will remove all bookmarks from the server for %@.", comment: "Message warning alert for removing all bookmarks from the server"), account.name)

      let alert = UIAlertController.init(title: nil, message: message, preferredStyle: .alert)

      let deleteAction = UIAlertAction.init(title: Strings.Generic.delete, style: .destructive, handler: { (action) in
        self.disableSync()
      })
      
      let cancelAction = UIAlertAction.init(title: Strings.Generic.cancel, style: .cancel, handler: { (action) in
        Log.info(#file, "User cancelled bookmark server delete.")
      })
      
      alert.addAction(deleteAction)
      alert.addAction(cancelAction)
      
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
  }
  
  private func disableSync() {
    self.account.details?.syncPermissionGranted = false;
    self.navigationController?.popViewController(animated: true)
  }
  
  // MARK: - UITableViewDataSource
  
  func numberOfSections(in tableView: UITableView) -> Int {
    return 1
  }
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return 1
  }
  
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell()
    cell.textLabel?.text = DisplayStrings.deleteServerData
    cell.textLabel?.font = UIFont.customFont(forTextStyle: .body)
    cell.textLabel?.textColor = .red
    return cell
  }

  func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    nil
  }
}
