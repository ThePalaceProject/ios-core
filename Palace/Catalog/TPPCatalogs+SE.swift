//
//  TPPCatalogNavigationController+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPCatalogNavigationController {
  @objc func didSignOut() {
  }
}

extension TPPCatalogFeedViewController {
  @objc func shouldLoad() -> Bool {
    return TPPSettings.shared.userHasSeenWelcomeScreen
  }
}
