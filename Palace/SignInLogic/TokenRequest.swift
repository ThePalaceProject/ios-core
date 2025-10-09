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
  
  func execute() async -> Result<TokenResponse, Error> {
    Log.info(#file, "Requesting token from: \(url.absoluteString)")
    
    var request = URLRequest(url: url, applyingCustomUserAgent: true)
    request.httpMethod = HTTPMethodType.POST.rawValue
    
    let loginString = "\(username):\(password)"
    guard let loginData = loginString.data(using: .utf8) else {
      Log.error(#file, "Failed to encode credentials")
      return .failure(URLError(.badURL))
    }
    let base64LoginString = loginData.base64EncodedString()
    request.addValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
    
    Log.debug(#file, "Sending POST request with Basic Auth")
    
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      
      Log.info(#file, "Token request returned \(data.count) bytes")
      
      if let httpResponse = response as? HTTPURLResponse {
        Log.info(#file, "Token request status: \(httpResponse.statusCode)")
        if httpResponse.statusCode != 200 {
          let errorMsg = String(data: data, encoding: .utf8) ?? "No error message"
          Log.error(#file, "Token request failed with status \(httpResponse.statusCode): \(errorMsg)")
          let error = NSError(domain: "TokenRequest", code: httpResponse.statusCode, 
                            userInfo: [NSLocalizedDescriptionKey: "Server returned status \(httpResponse.statusCode)"])
          return .failure(error)
        }
      }
      
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
      Log.info(#file, "Successfully decoded token response, expires in \(tokenResponse.expiresIn)s")
      return .success(tokenResponse)
    } catch {
      Log.error(#file, "Token request failed with error: \(error.localizedDescription)")
      if let urlError = error as? URLError {
        Log.error(#file, "URLError code: \(urlError.code.rawValue)")
      }
      if let decodingError = error as? DecodingError {
        Log.error(#file, "Decoding error: \(decodingError)")
      }
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
