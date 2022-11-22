//
//  TPPSettingsSplitViewController+OE.swift
//  Open eBooks
//
//  Created by Kyle Sakai.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

// The reason why this is here instead of directly inside the same source file
// of TPPSettingsSplitViewController is because the latter is meant as a
// foundation for both SimplyE and Open eBooks, while this extension is
// only meant for Open eBooks.
// - See: https://github.com/NYPL-Simplified/Simplified-iOS/pull/1070
extension TPPSettingsSplitViewController {
  typealias DisplayStrings = DisplayStrings.TPPSettingsSplitViewController
  
  /// Sets up the items of the `primaryTableVC`.
  func configPrimaryVCItems(using URLsProvider: TPPLibraryAccountURLsProvider) {
    let splitVC = self
    splitVC.primaryTableVC?.items = [
      TPPSettingsPrimaryTableItem.init(
        indexPath: IndexPath(row: 0, section: 0),
        title: Strings.account,
        selectionHandler: { (splitVC, tableVC) in
          if TPPUserAccount.sharedAccount().hasCredentials(),
            let currentLibraryID = AccountsManager.shared.currentAccountId {

            splitVC.showDetailViewController(
              TPPSettingsPrimaryTableItem.handleVCWrap(
                TPPSettingsAccountDetailViewController(
                  libraryAccountID: currentLibraryID
                )
              ),
              sender: nil
            )
          } else {
            OETutorialChoiceViewController.showLoginPicker(handler: nil)
          }
      }
      ),
      TPPSettingsPrimaryTableItem.init(
        indexPath: IndexPath(row: 0, section: 1),
        title: Strings.acknowledgements,
        viewController: TPPSettingsPrimaryTableItem.generateRemoteView(
          title: Strings.acknowledgements,
          url: URLsProvider.accountURL(forType: .acknowledgements)
        )
      ),
      TPPSettingsPrimaryTableItem.init(
        indexPath: IndexPath(row: 1, section: 1),
        title: Strings.eula,
        viewController: TPPSettingsPrimaryTableItem.generateRemoteView(
          title: Strings.eula,
          url: URLsProvider.accountURL(forType: .eula)
        )
      ),
      TPPSettingsPrimaryTableItem.init(
        indexPath: IndexPath(row: 2, section: 1),
        title: DisplayStrings.privacyPolicy,
        viewController: TPPSettingsPrimaryTableItem.generateRemoteView(
          title: DisplayStrings.privacyPolicy,
          url: URLsProvider.accountURL(forType: .privacyPolicy)
        )
      )
    ]
  }
}
