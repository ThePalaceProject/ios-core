//
//  TPPCatalogNavigationController+OE.swift
//  Open eBooks
//
//  Created by Ettore Pasquini on 9/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPCatalogNavigationController {
  @objc func didSignOut() {
    popToRootViewController(animated: true)

    loadTopLevelCatalogViewController()
  }
}

extension TPPCatalogFeedViewController {
  @objc func shouldLoad() -> Bool {
    return TPPUserAccount.sharedAccount().isSignedIn()
  }
}
