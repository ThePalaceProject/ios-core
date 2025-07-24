//
//  TPPBasicAuth.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 02/07/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import Security

/// Defines the interface required by the various pieces of the sign-in logic
/// to obtain the credentials for performing basic authentication.
@objc protocol NYPLBasicAuthCredentialsProvider: NSObjectProtocol {
  var username: String? {get}
  var pin: String? {get}
}

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
  @objc func handleChallenge(_ challenge: URLAuthenticationChallenge,
                             completion: BasicAuthCompletionHandler)
  {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodHTTPBasic:
      guard
        let username = credentialsProvider.username,
        let password = credentialsProvider.pin,
        challenge.previousFailureCount == 0 else {
          completion(.cancelAuthenticationChallenge, nil)
          return
      }
      
      let credentials = URLCredential(user: username,
                                      password: password,
                                      persistence: .none)
      completion(.useCredential, credentials)
      
    case NSURLAuthenticationMethodServerTrust:
      handleServerTrustChallenge(challenge, completion: completion)
      
    default:
      completion(.rejectProtectionSpace, nil)
    }
  }
  
  /// Enhanced server trust handling to work around malformed CRL issues
  private func handleServerTrustChallenge(_ challenge: URLAuthenticationChallenge,
                                        completion: BasicAuthCompletionHandler) {
    guard let serverTrust = challenge.protectionSpace.serverTrust else {
      Log.error(#file, "No server trust available for SSL challenge")
      completion(.cancelAuthenticationChallenge, nil)
      return
    }
    
    // Get the host for logging and policy creation
    let host = challenge.protectionSpace.host
    
    // Check if this host has known CRL issues
    if TPPNetworkConfiguration.shouldSkipCRLValidation(for: host) {
      Log.info(#file, "Host \(host) has known CRL issues, attempting validation without revocation checking")
      
      if let credential = validateWithoutCRL(serverTrust: serverTrust, host: host) {
        Log.info(#file, "SSL validation succeeded for \(host) using CRL workaround")
        completion(.useCredential, credential)
        return
      } else {
        Log.error(#file, "SSL validation failed for \(host) even with CRL workaround")
        completion(.cancelAuthenticationChallenge, nil)
        return
      }
    }
    
    // For other hosts, try default validation first
    var result = SecTrustResultType.invalid
    let defaultStatus = SecTrustEvaluate(serverTrust, &result)
    
    if defaultStatus == errSecSuccess && 
       (result == .unspecified || result == .proceed) {
      // Default validation succeeded
      let credential = URLCredential(trust: serverTrust)
      completion(.useCredential, credential)
      return
    }
    
    // Default validation failed - this could be due to unknown CRL issues
    Log.info(#file, "Default SSL validation failed for \(host) with status: \(defaultStatus)")
    completion(.performDefaultHandling, nil)
  }
  
  /// Attempt SSL validation with CRL checking disabled
  private func validateWithoutCRL(serverTrust: SecTrust, host: String) -> URLCredential? {
    // Create a policy that doesn't require revocation checking
    guard let policy = SecPolicyCreateSSL(true, host as CFString) else {
      Log.error(#file, "Failed to create SSL policy for \(host)")
      return nil
    }
    
    // Set the policy on the trust object
    let policyStatus = SecTrustSetPolicies(serverTrust, policy)
    guard policyStatus == errSecSuccess else {
      Log.error(#file, "Failed to set SSL policy for \(host)")
      return nil
    }
    
    // Disable revocation checking
    let options: [CFString: Any] = [
      kSecTrustRevocationPolicyNone: true
    ]
    
    SecTrustSetOptions(serverTrust, SecTrustOptionFlags(rawValue: 0))
    
    // Evaluate the trust
    var result = SecTrustResultType.invalid
    let status = SecTrustEvaluate(serverTrust, &result)
    
    if status == errSecSuccess && 
       (result == .unspecified || result == .proceed) {
      return URLCredential(trust: serverTrust)
    }
    
    Log.error(#file, "Custom SSL validation failed for \(host) with status: \(status), result: \(result.rawValue)")
    return nil
  }
}
