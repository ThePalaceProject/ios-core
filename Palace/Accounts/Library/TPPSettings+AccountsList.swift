//
//  TPPSettings+AccountsList.swift
//  Palace
//
//  Wave 1a relocation of the second half of TPPSettings+SE.swift (2020).
//  This is Accounts-domain logic (returns [Account], reads AccountsManager +
//  AppContainer) that lived in Palace/Settings/ only by cohabitation — moving
//  it here is what actually dissolves ledger cycle 5's Accounts→Settings edge.
//  KNOWN WARTS (preserved verbatim; PalaceAccounts-wave debt, not Wave 1a's):
//  reads/writes UserDefaults.standard directly (bypasses the injected
//  `defaults`), reaches AppContainer.production(), calls synchronize().
//

import Foundation
import PalacePreferences

extension TPPSettings {
    var settingsAccountIdsList: [String] {
        get {
            if let libraryAccounts = UserDefaults.standard.array(forKey: TPPSettings.settingsLibraryAccountsKey) as? [String] {
                return libraryAccounts
            }

            // Avoid crash in case currentLibrary isn't set yet
            var accountsList = [String]()
            if let currentLibrary = AppContainer.production().accountsManager.currentAccount?.uuid {
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
            .compactMap { AppContainer.production().accountsManager.account($0) }
            .sorted { $0.name < $1.name }
    }
}
