//
//  NetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

typealias NetworkManager = NetworkManagerAccount

protocol NetworkManagerAccount {  
  func fetchAuthenticationDocument(url: URL) -> AnyPublisher<OPDS2AuthenticationDocument?, NetworkManagerError>
  func fetchCatalog(url: URL) -> AnyPublisher<OPDS2CatalogsFeed?, NetworkManagerError>
  func clearCache()
}

extension NetworkManagerAccount {
  func fetchAuthenticationDocument(url: String) -> AnyPublisher<OPDS2AuthenticationDocument?, NetworkManagerError> {
    guard let targetUrl = URL(string: url) else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Failed to load authentication document because its URL is invalid",
        metadata: ["self.uuid": AccountsManager.shared.currentAccount?.uuid ?? "",
                   "urlString": url])
      
      return Fail(error: .invalidURL).eraseToAnyPublisher()
    }
    
    return fetchAuthenticationDocument(url: targetUrl)

}
  func fetchCatalog(url: String) -> AnyPublisher<OPDS2CatalogsFeed?, NetworkManagerError> {
      guard let targetUrl = URL(string: url) else {
        TPPErrorLogger.logError(
          withCode: .noURL,
          summary: "Failed to fetch catalogs because its URL is invalid",
          metadata: ["self.uuid": AccountsManager.shared.currentAccount?.uuid ?? "",
                     "urlString": url])

        return Fail(error: .invalidURL).eraseToAnyPublisher()
      }
      
      return fetchCatalog(url: targetUrl)
  }
}
