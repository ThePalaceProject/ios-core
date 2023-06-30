//
//  TokenRequest.swift
//  Palace
//
//  Created by Maurice Carrier on 6/28/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

struct TokenResponse: Codable {
  let accessToken: String
  let tokenType: String
  let expiresIn: Int
}

struct TokenRequest {
  let url: URL
  let username: String
  let password: String
  
  func execute() async throws -> TokenResponse {
    var request = URLRequest(url: url)
    request.httpMethod = HTTPMethodType.GET.rawValue
    
    let loginString = "\(username):\(password)"
    guard let loginData = loginString.data(using: .utf8) else {
      throw URLError(.badURL)
    }
    let base64LoginString = loginData.base64EncodedString()
    request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
    
    let (data, _) = try await URLSession.shared.data(for: request)
    
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(TokenResponse.self, from: data)
  }
}

