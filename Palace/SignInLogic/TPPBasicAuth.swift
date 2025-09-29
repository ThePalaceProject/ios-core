//
//  TPPBasicAuth.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 02/07/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - NYPLBasicAuthCredentialsProvider

/// Defines the interface required by the various pieces of the sign-in logic
/// to obtain the credentials for performing basic authentication.
@objc protocol NYPLBasicAuthCredentialsProvider: NSObjectProtocol {
  var username: String? { get }
  var pin: String? { get }
}

// MARK: - TPPBasicAuth

@objc class TPPBasicAuth: NSObject {
  typealias BasicAuthCompletionHandler = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

  /// The object providing the credentials to respond to the authentication
  /// challenge.
  private var credentialsProvider: NYPLBasicAuthCredentialsProvider

  @objc(initWithCredentialsProvider:)
  init(credentialsProvider: NYPLBasicAuthCredentialsProvider) {
    self.credentialsProvider = credentialsProvider
    super.init()
  }

  /// Responds to the authentication challenge synchronously.
  /// - Parameters:
  ///   - challenge: The authentication challenge to respond to.
  ///   - completion: Always called, synchronously.
  @objc func handleChallenge(
    _ challenge: URLAuthenticationChallenge,
    completion: BasicAuthCompletionHandler
  ) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodHTTPBasic:
      guard
        let username = credentialsProvider.username,
        let password = credentialsProvider.pin,
        challenge.previousFailureCount == 0
      else {
        completion(.cancelAuthenticationChallenge, nil)
        return
      }

      let credentials = URLCredential(
        user: username,
        password: password,
        persistence: .none
      )
      completion(.useCredential, credentials)

    case NSURLAuthenticationMethodServerTrust:
      completion(.performDefaultHandling, nil)

    default:
      completion(.rejectProtectionSpace, nil)
    }
  }
}
