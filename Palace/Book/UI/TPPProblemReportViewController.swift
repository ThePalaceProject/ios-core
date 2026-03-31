import UIKit
import MessageUI
import PureLayout

@objc protocol TPPProblemReportViewControllerDelegate: AnyObject {
  func problemReportViewController(_ controller: TPPProblemReportViewController, didSelectProblemWithType type: String)
}

@objc class TPPProblemReportViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

  @objc var book: TPPBook?
  @objc weak var delegate: TPPProblemReportViewControllerDelegate?

  @IBOutlet private var problemDescriptionTable: UITableView!
  private var submitProblemButton: UIBarButtonItem!

  private static let estimatedRowHeight: CGFloat = 44
  private static let problems: [[String: String]] = [
    ["type": "http://librarysimplified.org/terms/problem/wrong-genre", "title": "Wrong Genre"],
    ["type": "http://librarysimplified.org/terms/problem/wrong-audience", "title": "Wrong Audience"],
    ["type": "http://librarysimplified.org/terms/problem/wrong-age-range", "title": "Wrong Age Range"],
    ["type": "http://librarysimplified.org/terms/problem/wrong-title", "title": "Wrong Title"],
    ["type": "http://librarysimplified.org/terms/problem/wrong-medium", "title": "Wrong Medium"],
    ["type": "http://librarysimplified.org/terms/problem/wrong-author", "title": "Wrong Author"],
    ["type": "http://librarysimplified.org/terms/problem/bad-cover-image", "title": "Wrong/Missing Cover Image"],
    ["type": "http://librarysimplified.org/terms/problem/bad-description", "title": "Wrong/Mismatched Description"],
    ["type": "http://librarysimplified.org/terms/problem/cannot-fulfill-loan", "title": "Can't Download"],
    ["type": "http://librarysimplified.org/terms/problem/cannot-issue-loan", "title": "Can't Borrow"],
    ["type": "http://librarysimplified.org/terms/problem/cannot-render", "title": "Book Contents Blank or Incorrect"],
    ["type": "", "title": "Other..."]
  ]

  override func viewDidLoad() {
    super.viewDidLoad()

    submitProblemButton = UIBarButtonItem(
      title: NSLocalizedString("Submit", comment: ""),
      style: .done,
      target: self,
      action: #selector(submitProblem)
    )
    submitProblemButton.isEnabled = false
    navigationItem.rightBarButtonItem = submitProblemButton
    problemDescriptionTable?.backgroundColor = .white
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if presentingViewController?.traitCollection.horizontalSizeClass == .regular {
      navigationController?.setNavigationBarHidden(false, animated: false)
    }
  }

  @objc private func submitProblem() {
    guard let indexPath = problemDescriptionTable?.indexPathForSelectedRow else { return }
    let type = Self.problems[indexPath.row]["type"] ?? ""
    delegate?.problemReportViewController(self, didSelectProblemWithType: type)
  }

  @objc private func cancel() {
    if let navigationController = navigationController {
      navigationController.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func reportIssueVC() {
    if let email = AccountsManager.shared.currentAccount?.supportEmail {
      ProblemReportEmail.shared.beginComposing(
        to: email.rawValue,
        presentingViewController: self,
        book: book
      )
    } else if let url = AccountsManager.shared.currentAccount?.supportURL {
      presentWebView(url)
    }
  }

  private func presentWebView(_ url: URL) {
    let webController = BundledHTMLViewController(
      fileURL: url,
      title: AccountsManager.shared.currentAccount?.name
    )
    webController.hidesBottomBarWhenPushed = true
    navigationController?.pushViewController(webController, animated: true)
  }

  // MARK: - UITableViewDataSource

  func numberOfSections(in tableView: UITableView) -> Int {
    return 1
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return Self.problems.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "ProblemReportCell")
      ?? UITableViewCell(style: .default, reuseIdentifier: "ProblemReportCell")
    cell.textLabel?.text = Self.problems[indexPath.row]["title"]
    cell.textLabel?.font = UIFont.customFont(forTextStyle: .body)
    return cell
  }

  // MARK: - UITableViewDelegate

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let cell = tableView.cellForRow(at: indexPath)
    let typeLabel = Self.problems[indexPath.row]["type"] ?? ""

    if typeLabel.isEmpty {
      tableView.deselectRow(at: indexPath, animated: true)
      reportIssueVC()
    } else {
      cell?.accessoryType = .checkmark
      if !submitProblemButton.isEnabled {
        submitProblemButton.isEnabled = true
      }
    }
  }

  func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    let cell = tableView.cellForRow(at: indexPath)
    cell?.accessoryType = .none
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    return UITableView.automaticDimension
  }

  func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
    return Self.estimatedRowHeight
  }
}
