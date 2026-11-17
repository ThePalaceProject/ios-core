//
//  TPPSettings+AccountsList.swift
//  Palace
//
//  Accounts-domain part of TPPSettings (returns [Account], reads AccountsManager),
//  kept here so Accounts does not depend on Settings.
//  Known debt: uses UserDefaults.standard directly (not the injected `defaults`),
//  reaches AppContainer.production(), and calls synchronize().
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
