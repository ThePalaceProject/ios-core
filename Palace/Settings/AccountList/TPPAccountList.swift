import Foundation


/// List of available Libraries/Accounts to select as patron's primary
/// when going through Welcome Screen flow.
final class TPPAccountList: UIViewController {
  
  var datasource = TPPAccountListDataSource()
  
  var searchBar: UISearchBar!
  var tableView : UITableView!

  let completion: (Account) -> ()
  
  private var numberOfSections = 2
  private var estimatedRowHeight: CGFloat = 100
  private var sectionHeaderSize: CGFloat = 20
  
  @objc required init(completion: @escaping (Account) -> ()) {
    self.completion = completion
    super.init(nibName:nil, bundle:nil)
  }
  
  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    configure()
  }
  
  private func configure() {
    let stackView = UIStackView()
    stackView.axis = .vertical

    searchBar = UISearchBar()
    searchBar.backgroundColor = TPPConfiguration.backgroundColor()
    searchBar.delegate = datasource
    
    tableView = UITableView(frame: .zero, style: .grouped)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.estimatedRowHeight = estimatedRowHeight
    tableView.backgroundColor = TPPConfiguration.backgroundColor()
    
    stackView.addArrangedSubview(searchBar)
    stackView.addArrangedSubview(tableView)
    
    view.addSubview(stackView)
    stackView.autoPinEdge(toSuperviewMargin: .top)
    stackView.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
    
    title = datasource.title
    view.backgroundColor = TPPConfiguration.backgroundColor()
    tableView.register(TPPAccountListCell.self, forCellReuseIdentifier: TPPAccountListCell.reuseIdentifier)
    datasource.delegate = self
  }
}

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
    UIView(frame: .zero)
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == .zero ? .zero : sectionHeaderSize
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    datasource.accounts(in: section)
  }
  
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let cell = tableView.dequeueReusableCell(withIdentifier: TPPAccountListCell.reuseIdentifier, for: indexPath) as? TPPAccountListCell else { return UITableViewCell() }
    
    cell.configure(for: datasource.account(at: indexPath))
    return cell
  }
}

extension TPPAccountList: DataSourceDelegate {
  func refresh() {
    tableView.reloadData()
  }
}
