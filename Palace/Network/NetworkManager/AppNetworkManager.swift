//
//  AppNetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

class AppNetworkManager {}

extension AppNetworkManager: NetworkManagerAccount {

  func fetchAuthenticationDocument(url: String) -> AnyPublisher<OPDS2AuthenticationDocument?, NetworkManagerError> {
    guard let targetUrl = URL(string: url) else { return Fail(error: .invalidURL).eraseToAnyPublisher() }

    return Future<OPDS2AuthenticationDocument?, NetworkManagerError> { promise in
      TPPNetworkExecutor.shared.GET(targetUrl) { result in
        switch result {
        case let .success(data, _):
          
          do {
            let document = try OPDS2AuthenticationDocument.fromData(data)
            promise(.success(document))
          } catch (let error) {
            
            let responseBody = String(data: data, encoding: .utf8)
            TPPErrorLogger.logError(
              withCode: .authDocParseFail,
              summary: "Authentication Document Data Parse Error",
              metadata: [
                "underlyingError": error,
                "responseBody": responseBody ?? "N/A",
                "url": url
              ]
            )
            
            promise(.failure(.internalError(.authDocParseFail)))
          }

        case let .failure(error, _):
          TPPErrorLogger.logError(
            withCode: .authDocLoadFail,
            summary: "Authentication Document request failed to load",
            metadata: ["loadError": error, "url": url]
          )
          
          promise(.failure(.internalError(.authDocLoadFail)))
        }
      }
    }
    .eraseToAnyPublisher()
  }
  
  func fetchAccount(url: String) -> AnyPublisher<Account?, NetworkManagerError> {
    Fail(error: .internalError(.feedParseFail))
      .eraseToAnyPublisher()
  }
  
  func fetchCatalog(url: String) -> AnyPublisher<OPDS2CatalogsFeed?, NetworkManagerError> {
    guard let targetUrl = URL(string: url) else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Failed to load authentication document because its URL is invalid",
        metadata: ["self.uuid": AccountsManager.shared.currentAccount?.uuid ?? "",
                   "urlString": url])
      
      return Fail(error: .invalidURL).eraseToAnyPublisher()
    }
    
    return Future<OPDS2CatalogsFeed?, NetworkManagerError> { promise in
      TPPNetworkExecutor.shared.GET(targetUrl) { result in
        switch result {
        case let .success(data, _):
          
          do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            promise(.success(feed))
          } catch (let error) {
            let responseBody = String(data: data, encoding: .utf8)
            TPPErrorLogger.logError(
              withCode: .authDocParseFail,
              summary: "Authentication Document Data Parse Error",
              metadata: [
                "underlyingError": error,
                "responseBody": responseBody ?? "N/A",
                "url": url
              ]
            )

            promise(.failure(.internalError(.authDocParseFail)))
          }
          
        case let .failure(error, _):
          TPPErrorLogger.logError(error, summary: "Error while parsing catalog feed")
          promise(.failure(.serverError(error)))
        }
      }
    }
    .eraseToAnyPublisher()
  }
}

extension AppNetworkManager: NetworkManagerCatalogFeed{
  
  func fetchFeed(url: String) -> AnyPublisher<TPPOPDSFeed?, NetworkManagerError> {
    Fail(error: .internalError(.authDocParseFail))
      .eraseToAnyPublisher()
  }
}
