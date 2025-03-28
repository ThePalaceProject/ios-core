import Foundation


/// List of available Libraries/Accounts to select as patron's primary
/// when going through Welcome Screen flow.
@objc final class TPPAccountList: UIViewController {

  private let completion: (Account) -> ()
  private var loadingView: UIActivityIndicatorView?

  var datasource = TPPAccountListDataSource()
  var searchBar: UISearchBar!
  var tableView: UITableView!

  private var numberOfSections = 2
  private var estimatedRowHeight: CGFloat = 100
  private var sectionHeaderSize: CGFloat = 20

  @objc required init(completion: @escaping (Account) -> ()) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TPPConfiguration.backgroundColor()
    title = datasource.title

    setupUI()

    if AccountsManager.shared.accountsHaveLoaded {
      finishConfiguration()
    } else {
      showLoading()
      AccountsManager.shared.loadCatalogs { success in
        DispatchQueue.main.async {
          self.hideLoading()
          success ? self.finishConfiguration() : self.showLoadingFailureAlert()
          self.datasource.loadData()
          self.tableView.reloadData()
        }
      }
    }
  }

  private func setupUI() {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.translatesAutoresizingMaskIntoConstraints = false

    searchBar = UISearchBar()
    searchBar.backgroundColor = TPPConfiguration.backgroundColor()
    searchBar.delegate = datasource

    tableView = UITableView(frame: .zero, style: .grouped)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.estimatedRowHeight = estimatedRowHeight
    tableView.backgroundColor = TPPConfiguration.backgroundColor()
    tableView.register(TPPAccountListCell.self, forCellReuseIdentifier: TPPAccountListCell.reuseIdentifier)

    stackView.addArrangedSubview(searchBar)
    stackView.addArrangedSubview(tableView)
    view.addSubview(stackView)

    stackView.autoPinEdge(toSuperviewMargin: .top)
    stackView.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
  }

  private func finishConfiguration() {
    datasource.delegate = self
    tableView.reloadData()
  }

  private func showLoading() {
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.startAnimating()
    spinner.center = view.center
    view.addSubview(spinner)
    loadingView = spinner
  }

  private func hideLoading() {
    loadingView?.stopAnimating()
    loadingView?.removeFromSuperview()
    loadingView = nil
  }

  private func showLoadingFailureAlert() {
    let alert = TPPAlertUtils.alert(
      title: nil,
      message: "We can’t get your library right now. Please close and reopen the app to try again.",
      style: .cancel
    )
    present(alert, animated: true)
  }
}

// MARK: - UITableViewDelegate/DataSource
extension TPPAccountList: UITableViewDelegate, UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int {
    numberOfSections
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    UITableView.automaticDimension
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    completion(datasource.account(at: indexPath))
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    UIView()
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == 0 ? 0 : sectionHeaderSize
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    datasource.accounts(in: section)
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let cell = tableView.dequeueReusableCell(withIdentifier: TPPAccountListCell.reuseIdentifier, for: indexPath) as? TPPAccountListCell else {
      return UITableViewCell()
    }
    cell.configure(for: datasource.account(at: indexPath))
    return cell
  }
}

// MARK: - DataSourceDelegate
extension TPPAccountList: DataSourceDelegate {
  func refresh() {
    tableView.reloadData()
  }
}

extension TPPAccountList: AccountLogoDelegate {
  func logoDidUpdate(in account: Account, to newLogo: UIImage) {
    if let indexPath = datasource.indexPath(for: account) {
      DispatchQueue.main.async {
        self.tableView.reloadRows(at: [indexPath], with: .automatic)
      }
    }
  }
}
