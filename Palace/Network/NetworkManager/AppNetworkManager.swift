//
//  AppNetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 10/15/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import Combine

class AppNetworkManager {
  let executor: NetworkExecutor

  init(executor: NetworkExecutor = TPPNetworkExecutor.shared) {
    self.executor = executor
  }
}

extension AppNetworkManager: NetworkManagerAccount {
  func fetchAuthenticationDocument(url: URL) -> AnyPublisher<OPDS2AuthenticationDocument?, NetworkManagerError> {
    return Future<OPDS2AuthenticationDocument?, NetworkManagerError> { [weak self] promise in
      self?.executor.GET(url) { result in
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
  
  func fetchCatalog(url: URL) -> AnyPublisher<OPDS2CatalogsFeed?, NetworkManagerError> {
    return Future<OPDS2CatalogsFeed?, NetworkManagerError> { [weak self] promise in
      self?.executor.GET(url) { result in
        switch result {
        case let .success(data, _):
          
          do {
            let feed = try OPDS2CatalogsFeed.fromData(data)
            promise(.success(feed))
          } catch (let error) {
            let responseBody = String(data: data, encoding: .utf8)
            TPPErrorLogger.logError(
              withCode: .libraryListLoadFail,
              summary: "Unable to load libraries list",
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
  
  func clearCache() {
    TPPNetworkExecutor.shared.clearCache()
  }
}
