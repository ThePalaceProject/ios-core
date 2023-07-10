//
//  TokenRequest.swift
//  Palace
//
//  Created by Maurice Carrier on 6/28/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

@objc class TokenResponse: NSObject, Codable {
  @objc let accessToken: String
  let tokenType: String
  let expiresIn: Int
  
  @objc init(accessToken: String, tokenType: String, expiresIn: Int) {
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.expiresIn = expiresIn
  }
}

@objc class TokenRequest: NSObject {
  let url: URL
  let username: String
  let password: String
  
  @objc init(url: URL, username: String, password: String) {
    self.url = url
    self.username = username
    self.password = password
  }
  
  func execute() async -> Result<TokenResponse, Error> {
    var request = URLRequest(url: url)
    request.httpMethod = HTTPMethodType.GET.rawValue
    
    let loginString = "\(username):\(password)"
    guard let loginData = loginString.data(using: .utf8) else {
      return .failure(URLError(.badURL))
    }
    
    let base64LoginString = loginData.base64EncodedString()
    request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
    
    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
      return .success(tokenResponse)
    } catch {
      return .failure(error)
    }
  }
}

extension TokenRequest {
  @objc func execute(completion: @escaping (TokenResponse?, Error?) -> Void) {
    Task {
      let result = await execute()
      switch result {
      case .success(let tokenResponse):
        completion(tokenResponse, nil)
      case .failure(let error):
        completion(nil, error)
      }
    }
  }
}
