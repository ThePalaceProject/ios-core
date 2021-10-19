//
//  NetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

protocol NetworkManagerAccount {  
  func fetchAuthenticationDocument(url: String) -> AnyPublisher<OPDS2AuthenticationDocument?, NetworkManagerError>
  func fetchAccount(url: String) -> AnyPublisher<Account?, NetworkManagerError>
  func fetchCatalog(url: String) -> AnyPublisher<OPDS2CatalogsFeed?, NetworkManagerError>
}

protocol NetworkManagerCatalogFeed {
  func fetchFeed(url: String) -> AnyPublisher<TPPOPDSFeed?, NetworkManagerError>
}

typealias NetworkManager = NetworkManagerAccount & NetworkManagerCatalogFeed
