//
//  AppEvent.swift
//  Palace
//
//  Created by Maurice Carrier on 10/19/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

typealias Completion = () -> Void

enum AppEvent {
  case setCurrentAccount(Account)
  case updateAccountSet
  case loadCatalog(OPDS2CatalogsFeed)
}
