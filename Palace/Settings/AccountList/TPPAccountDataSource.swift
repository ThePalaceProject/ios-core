//
//  TPPAccountDataSource.swift
//  Palace
//
//  Created by Maurice Work on 6/24/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

struct TPPAccountDataSource {
  
  var title: String = NSLocalizedString("Pick Your Library", comment: "Title that also informs the user that they should choose a library from the list.")
  private var accounts: [Account]!
  private var nyplAccounts: [Account]!
  
  init() {
    self.accounts = AccountsManager.shared.accounts()
    self.accounts.sort { $0.name < $1.name }
    self.nyplAccounts = self.accounts.filter { AccountsManager.TPPAccountUUIDs.contains($0.uuid) }
    self.accounts = self.accounts.filter { !AccountsManager.TPPAccountUUIDs.contains($0.uuid) }
  }
  
  func accounts(in section: Int) -> Int {
    section == .zero ? nyplAccounts.count : accounts.count
  }
  
  func account(at indexPath: IndexPath) -> Account {
    indexPath.section == .zero ? nyplAccounts[indexPath.row] : accounts[indexPath.row]
  }
}

