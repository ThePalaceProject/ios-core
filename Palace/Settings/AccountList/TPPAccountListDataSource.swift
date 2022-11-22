import Foundation

protocol DataSourceDelegate: AnyObject {
  func refresh()
}

class TPPAccountListDataSource: NSObject {

  weak var delegate: DataSourceDelegate?
  var title: String = NSLocalizedString("Add Library", comment: "Title that also informs the user that they should choose a library from the list.")
  
  private var accounts: [Account]!
  private var nationalAccounts: [Account]!
  
  override init() {
    super.init()
    loadData()
  }
  
  private func loadData(_ filterString: String? = nil) {
    accounts = AccountsManager.shared.accounts()
    accounts.sort { $0.name < $1.name }
    
    if let filter = filterString, !filter.isEmpty {
      nationalAccounts = self.accounts.filter { AccountsManager.TPPNationalAccountUUIDs.contains($0.uuid) && $0.name.range(of: filter, options: .caseInsensitive) != nil }
      accounts = self.accounts.filter { !AccountsManager.TPPNationalAccountUUIDs.contains($0.uuid) && $0.name.range(of: filter, options: .caseInsensitive) != nil }
    } else {
      nationalAccounts = self.accounts.filter { AccountsManager.TPPNationalAccountUUIDs.contains($0.uuid) }
      accounts = self.accounts.filter { !AccountsManager.TPPNationalAccountUUIDs.contains($0.uuid) }
    }
    
    delegate?.refresh()
  }
  
  func accounts(in section: Int) -> Int {
    section == .zero ? nationalAccounts.count : accounts.count
  }
  
  func account(at indexPath: IndexPath) -> Account {
    indexPath.section == .zero ? nationalAccounts[indexPath.row] : accounts[indexPath.row]
  }
}


extension TPPAccountListDataSource: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    loadData(searchText)
  }
  
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    loadData(searchBar.text)
    searchBar.resignFirstResponder()
  }
  
  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    searchBar.text = ""
    loadData()
    searchBar.resignFirstResponder()
  }
}
