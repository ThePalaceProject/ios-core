//
//  SSLErrorHandler.swift
//  Palace
//
//  Created by AI Assistant on SSL CRL Issue Fix
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

/// Handles SSL/TLS related errors including certificate validation issues
@objc class SSLErrorHandler: NSObject {
  
  /// Error codes related to SSL/certificate issues
  enum SSLErrorType {
    case crlDecodingFailed
    case certificateRevoked
    case certificateExpired
    case untrustedCertificate
    case networkError
    case unknown
  }
  
  /// Analyze an error to determine if it's SSL/certificate related
  /// - Parameter error: The error to analyze
  /// - Returns: The SSL error type if applicable, nil otherwise
  static func analyzeSSLError(_ error: Error) -> SSLErrorType? {
    let errorDescription = error.localizedDescription.lowercased()
    let domain = (error as NSError).domain
    
    // Check for CRL-specific errors
    if errorDescription.contains("crl") && errorDescription.contains("decoding") {
      return .crlDecodingFailed
    }
    
    if errorDescription.contains("revocation") {
      return .certificateRevoked
    }
    
    if errorDescription.contains("certificate") {
      if errorDescription.contains("expired") {
        return .certificateExpired
      } else if errorDescription.contains("untrusted") || errorDescription.contains("invalid") {
        return .untrustedCertificate
      }
    }
    
    if domain == NSURLErrorDomain {
      let code = (error as NSError).code
      switch code {
      case NSURLErrorServerCertificateUntrusted,
           NSURLErrorServerCertificateHasBadDate,
           NSURLErrorServerCertificateNotYetValid:
        return .untrustedCertificate
      case NSURLErrorNetworkConnectionLost,
           NSURLErrorNotConnectedToInternet:
        return .networkError
      default:
        break
      }
    }
    
    return nil
  }
  
  /// Create a user-friendly error message for SSL issues
  /// - Parameters:
  ///   - errorType: The type of SSL error
  ///   - host: The host that caused the error (optional)
  /// - Returns: A localized error message
  static func userFriendlyMessage(for errorType: SSLErrorType, host: String? = nil) -> String {
    let hostInfo = host.map { " (\($0))" } ?? ""
    
    switch errorType {
    case .crlDecodingFailed:
      return """
      There's a security configuration issue with the library server\(hostInfo). 
      This is a temporary server-side problem that should be resolved soon. 
      Please try again later or contact your library for assistance.
      """
      
    case .certificateRevoked:
      return """
      The library server's security certificate has been revoked\(hostInfo). 
      Please contact your library's technical support for assistance.
      """
      
    case .certificateExpired:
      return """
      The library server's security certificate has expired\(hostInfo). 
      Please contact your library's technical support for assistance.
      """
      
    case .untrustedCertificate:
      return """
      There's an issue with the library server's security certificate\(hostInfo). 
      Please check your internet connection and try again, or contact your library for support.
      """
      
    case .networkError:
      return """
      Network connection issue\(hostInfo). 
      Please check your internet connection and try again.
      """
      
    case .unknown:
      return """
      An unexpected security error occurred\(hostInfo). 
      Please try again later or contact support if the problem persists.
      """
    }
  }
  
  /// Present an alert for SSL errors with user-friendly messaging
  /// - Parameters:
  ///   - error: The original error
  ///   - host: The host that caused the error (optional)
  ///   - viewController: The view controller to present the alert from
  @objc static func presentSSLErrorAlert(for error: Error, 
                                         host: String? = nil, 
                                         from viewController: UIViewController?) {
    guard let sslErrorType = analyzeSSLError(error) else {
      // Not an SSL error, handle normally
      return
    }
    
    let title = "Connection Security Issue"
    let message = userFriendlyMessage(for: sslErrorType, host: host)
    
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    
    // Add retry action for certain error types
    if sslErrorType == .crlDecodingFailed || sslErrorType == .networkError {
      alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
        // Trigger a retry - this could be implemented based on context
        NotificationCenter.default.post(name: .retryLastOperation, object: nil)
      })
    }
    
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    
    DispatchQueue.main.async {
      viewController?.present(alert, animated: true)
    }
  }
}

// MARK: - Notification Extensions
extension Notification.Name {
  static let retryLastOperation = Notification.Name("TPPRetryLastOperation")
} 