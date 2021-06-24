import Foundation


/// List of available Libraries/Accounts to select as patron's primary
/// when going through Welcome Screen flow.
final class TPPAccountList: UITableViewController {
  
  var datasource = TPPAccountDataSource()

  let completion: (Account) -> ()
  private var numberOfSections = 2
  
  required init(completion: @escaping (Account) -> ()) {
    self.completion = completion
    super.init(style: .grouped)
  }
  
  @available(*, unavailable)
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func viewDidLoad() {
    title = datasource.title
    view.backgroundColor = TPPConfiguration.backgroundColor()
    tableView.estimatedRowHeight = 100
  }
  
  override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    UITableView.automaticDimension
  }
  
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    completion(datasource.account(at: indexPath))
  }
  
  override func numberOfSections(in tableView: UITableView) -> Int {
    numberOfSections
  }
  
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    datasource.accounts(in: section)
  }
  
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    TPPAccountListCell(datasource.account(at: indexPath))
  }
}
