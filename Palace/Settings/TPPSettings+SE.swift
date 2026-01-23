//
//  TPPSettings+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/17/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

extension TPPSettings: NYPLUniversalLinksSettings {
  /// Used to handle Clever and SAML sign-ins in SimplyE.
  @objc var universalLinksURL: URL {
    return URL(string: "https://librarysimplified.org/callbacks/SimplyE")!
  }
}

extension TPPSettings {
  var settingsAccountIdsList: [String] {
    get {
      if let libraryAccounts = UserDefaults.standard.array(forKey: TPPSettings.settingsLibraryAccountsKey) as? [String] {
        return libraryAccounts
      }

      // Avoid crash in case currentLibrary isn't set yet
      var accountsList = [String]()
      if let currentLibrary = AccountsManager.shared.currentAccount?.uuid {
        accountsList.append(currentLibrary)
      }
      accountsList.append(AccountsManager.TPPAccountUUIDs[2])
      self.settingsAccountIdsList = accountsList
      return accountsList
    }
    set(newAccountsList) {
      UserDefaults.standard.set(newAccountsList, forKey: TPPSettings.settingsLibraryAccountsKey)
      UserDefaults.standard.synchronize()
    }
  }
  
  var settingsAccountsList: [Account] {
    settingsAccountIdsList
      .compactMap { AccountsManager.shared.account($0) }
      .sorted { $0.name < $1.name }
  }
}
