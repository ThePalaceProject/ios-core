//
//  TPPearerAuth.swift
//  Palace
//
//  Created by Maurice Carrier on 7/12/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

@objc protocol NYPLAuthTokenProvider: NSObjectProtocol {
  var authToken: String? {get}
}

@objc class TPPBearerAuth: NSObject {
  typealias BearerAuthCompletionHandler = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  
  /// The object providing the authToken to respond to the authentication
  /// challenge.
  private var tokenProvider: NYPLAuthTokenProvider
  
  @objc(initWithTokenProvider:)
  init(tokenProvider: NYPLAuthTokenProvider) {
    self.tokenProvider = tokenProvider
    super.init()
  }
  
  /// Responds to the authentication challenge synchronously.
  /// - Parameters:
  ///   - challenge: The authentication challenge to respond to.
  ///   - completion: Always called, synchronously.
  @objc func handleChallenge(_ challenge: URLAuthenticationChallenge,
                             completion: BearerAuthCompletionHandler)
  {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      guard
        let authToken = tokenProvider.authToken,
        challenge.previousFailureCount == 0 else {
        completion(.cancelAuthenticationChallenge, nil)
        return
      }
      
      let tokenString = "Bearer \(authToken)"
      let credential = URLCredential(user: tokenString,
                                     password: "",
                                     persistence: .none)
      completion(.useCredential, credential)

    case NSURLAuthenticationMethodServerTrust:
      completion(.performDefaultHandling, nil)
      
    default:
      completion(.rejectProtectionSpace, nil)
    }
  }
}
