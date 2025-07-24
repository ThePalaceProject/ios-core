//
//  TPPNetworkConfiguration.swift
//  Palace
//
//  Created by AI Assistant on SSL CRL Issue Fix
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import Foundation

/// Configuration for network-related settings and workarounds
@objc class TPPNetworkConfiguration: NSObject {
  
  /// Hosts known to have malformed CRL data that should skip revocation checking
  static let hostsWithCRLIssues: Set<String> = [
    "ga.thepalaceproject.org",
    // Add other problematic hosts here as needed
  ]
  
  /// Check if a host is known to have CRL issues
  /// - Parameter host: The hostname to check
  /// - Returns: True if the host should skip CRL validation
  @objc static func shouldSkipCRLValidation(for host: String) -> Bool {
    return hostsWithCRLIssues.contains(host)
  }
  
  /// Check if a URL's host has known CRL issues
  /// - Parameter url: The URL to check
  /// - Returns: True if the URL's host should skip CRL validation
  @objc static func shouldSkipCRLValidation(for url: URL) -> Bool {
    guard let host = url.host else { return false }
    return shouldSkipCRLValidation(for: host)
  }
} 