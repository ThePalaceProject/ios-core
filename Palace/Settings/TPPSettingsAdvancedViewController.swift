import UIKit

/// Advanced Menu in Settings
@objcMembers class TPPSettingsAdvancedViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  typealias DisplayStrings = Strings.TPPSettingsAdvancedViewController

  var account: Account

  init(account id: String) {
    account = AccountsManager.shared.account(id)!
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = DisplayStrings.advanced

    let tableView = UITableView(frame: .zero, style: .grouped)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.backgroundColor = TPPConfiguration.backgroundColor()
    view.addSubview(tableView)
    tableView.autoPinEdgesToSuperviewEdges()
  }

  // MARK: - UITableViewDelegate

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if indexPath.row == 0 {
      let cell = tableView.cellForRow(at: indexPath)
      cell?.setSelected(false, animated: true)

      let message = String.localizedStringWithFormat(
        NSLocalizedString(
          "Selecting \"Delete\" will remove all bookmarks from the server for %@.",
          comment: "Message warning alert for removing all bookmarks from the server"
        ),
        account.name
      )

      let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)

      let deleteAction = UIAlertAction(title: Strings.Generic.delete, style: .destructive, handler: { _ in
        self.disableSync()
      })

      let cancelAction = UIAlertAction(title: Strings.Generic.cancel, style: .cancel, handler: { _ in
        Log.info(#file, "User cancelled bookmark server delete.")
      })

      alert.addAction(deleteAction)
      alert.addAction(cancelAction)

      TPPAlertUtils.presentFromViewControllerOrNil(
        alertController: alert,
        viewController: nil,
        animated: true,
        completion: nil
      )
    }
  }

  private func disableSync() {
    account.details?.syncPermissionGranted = false
    navigationController?.popViewController(animated: true)
  }

  // MARK: - UITableViewDataSource

  func numberOfSections(in _: UITableView) -> Int {
    1
  }

  func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
    1
  }

  func tableView(_: UITableView, cellForRowAt _: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell()
    cell.textLabel?.text = DisplayStrings.deleteServerData
    cell.textLabel?.font = UIFont.customFont(forTextStyle: .body)
    cell.textLabel?.textColor = .red
    return cell
  }

  func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
    nil
  }
}
