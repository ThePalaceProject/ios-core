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
  @objc let expiresIn: Int
  
  @objc init(accessToken: String, tokenType: String, expiresIn: Int) {
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.expiresIn = expiresIn
  }
}

@objc extension TokenResponse {
  @objc var expirationDate: Date {
    Date(timeIntervalSinceNow: Double(expiresIn))
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
  
//  func execute() async -> Result<TokenResponse, Error> {
//    var request = URLRequest(url: url, applyingCustomUserAgent: true)
//    request.httpMethod = HTTPMethodType.POST.rawValue
//    
//    let loginString = "\(username):\(password)"
//    guard let loginData = loginString.data(using: .utf8) else {
//      return .failure(URLError(.badURL))
//    }
//    let base64LoginString = loginData.base64EncodedString()
//    request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
// 
//    do {
//      let (data, _) = try await URLSession.shared.data(for: request)
//
//      let decoder = JSONDecoder()
//      decoder.keyDecodingStrategy = .convertFromSnakeCase
//      let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
//      return .success(tokenResponse)
//    } catch {
//      return .failure(error)
//    }
//  }
  func execute() async -> Result<TokenResponse, Error> {
    print("DEBUG: Starting token request execution.")

    var request = URLRequest(url: url, applyingCustomUserAgent: true)
    request.httpMethod = HTTPMethodType.POST.rawValue
    print("DEBUG: Request URL - \(url.absoluteString)")
    print("DEBUG: HTTP Method - \(request.httpMethod ?? "N/A")")

    let loginString = "\(username):\(password)"
    print("DEBUG: Creating login string for basic auth.")
    guard let loginData = loginString.data(using: .utf8) else {
      print("DEBUG: Failed to encode login string using UTF-8.")
      return .failure(URLError(.badURL))
    }

    let base64LoginString = loginData.base64EncodedString()
    print("DEBUG: Base64 encoded login string generated.")
    request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
    print("DEBUG: Authorization header set.")

    do {
      print("DEBUG: Initiating network call using URLSession.")
      let (data, response) = try await URLSession.shared.data(for: request)

      print("DEBUG: Network call completed. Data received: \(data.count) bytes.")
      if let httpResponse = response as? HTTPURLResponse {
        print("DEBUG: HTTP Response status code: \(httpResponse.statusCode)")
      }

      // Debug: Print out the raw response string
      if let responseString = String(data: data, encoding: .utf8) {
        print("DEBUG: Raw response data: \(responseString)")
      } else {
        print("DEBUG: Unable to convert response data to string")
      }

      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      print("DEBUG: Attempting to decode token response.")
      let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
      print("DEBUG: Successfully decoded token response.")
      return .success(tokenResponse)
    } catch {
      print("DEBUG: Error during network call or decoding: \(error.localizedDescription)")
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
