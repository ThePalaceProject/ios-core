//
//  NetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 8/10/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

protocol PreviewDownloader {
  static func fetchPreview(query: String, completion: @escaping(Swift.Result<EpubPreviewResponseModel, NetworkManagerError>) -> Void)
}

protocol NetworkManager {
  func sendRequest<T: Codable>(request: RequestModel, completion: @escaping (Swift.Result<T, NetworkManagerError>) -> Void)
}

extension NetworkManager {
  func sendRequest<T: Codable>(request: RequestModel, completion: @escaping (Swift.Result<T, NetworkManagerError>) -> Void) {
         URLSession.shared.dataTask(with: request.urlRequest()) { data, response, error in
             
             let decoder = JSONDecoder()
             decoder.keyDecodingStrategy = .convertFromSnakeCase
             
             guard let data = data else {
               return completion(Result.failure(NetworkManagerError.previewFetchFailed))
             }
             
             DispatchQueue.main.async {
                 switch T.self {
                     case is EpubPreviewResponseModel.Type:
                         guard let responseModel = try? decoder.decode(T.self, from: data) else {
                             completion(Result.failure(NetworkManagerError.previewDecodeFailed))
                             return
                         }
                         completion(Result.success(responseModel))
                     
                 default:
                     completion(Result.failure(NetworkManagerError.internalError))
                 }
             }
         }.resume()
     }
}

struct AppNetworkManager: NetworkManager {
  static let shared = AppNetworkManager()
}

extension AppNetworkManager: PreviewDownloader {

  /**
     featchPreview
     
     - Parameter query: Text query to search
     - Parameter completion: closure block, returns Swift Result
     */
  static func fetchPreview(query: String, completion: @escaping(Swift.Result<EpubPreviewResponseModel, NetworkManagerError>) -> Void) {
    AppNetworkManager.shared.sendRequest(request: EpubPreviewRequestModel(path: query)) { result in
      completion(result)
    }
  }
}
