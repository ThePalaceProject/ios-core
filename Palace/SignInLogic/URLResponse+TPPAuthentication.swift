//
//  URLResponse+TPPAuthentication.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension URLResponse {

  /// Attempts to determine if the response indicates that the user's
  /// credentials are expired or invalid.
  ///
  /// The idea is that if the user was authenticated and an error is returned,
  /// this may indicate that the credentials that were used in the request
  /// are no longer valid. The problem document, if available, is the
  /// primary source of truth.
  ///
  /// You could use this api even when the user was not authenticated to begin
  /// with, but in that case you'd already know the reason of the error.
  ///
  /// - Parameter problemDoc: The problem document returned by the server.
  /// - Returns: `true` if the response or problem document indicate that the
  /// authentication needs to be refreshed.
  @objc(indicatesAuthenticationNeedsRefresh:)
  func indicatesAuthenticationNeedsRefresh(with problemDoc: TPPProblemDocument?) -> Bool {
    return isProblemDocument() && problemDoc?.type == TPPProblemDocument.TypeInvalidCredentials 
  }
  
  /// Checks if this response came from the same domain as the given URL.
  /// Compares base domains (e.g., palaceproject.io) rather than full hosts,
  /// so cdn.palaceproject.io and gorgon.palaceproject.io are considered the same.
  ///
  /// - Parameter otherURL: The URL to compare against.
  /// - Returns: `true` if both URLs share the same base domain.
  func isSameDomain(as otherURL: URL) -> Bool {
    guard let responseHost = self.url?.host?.lowercased(),
          let otherHost = otherURL.host?.lowercased() else {
      // If we can't determine hosts, assume same domain (safe default)
      return true
    }
    
    // Exact match
    if responseHost == otherHost {
      return true
    }
    
    // Compare base domains (last two parts of the host)
    let responseBase = URLResponse.baseDomain(from: responseHost)
    let otherBase = URLResponse.baseDomain(from: otherHost)
    
    return responseBase == otherBase
  }
  
  /// Extracts the base domain from a host string.
  /// e.g., "cdn.palaceproject.io" -> "palaceproject.io"
  ///       "gorgon.staging.palaceproject.io" -> "palaceproject.io"
  static func baseDomain(from host: String) -> String {
    let components = host.split(separator: ".")
    
    // Handle simple domains like "localhost"
    guard components.count >= 2 else {
      return host
    }
    
    // Return last two components (e.g., "palaceproject.io")
    return components.suffix(2).joined(separator: ".")
  }
}

extension HTTPURLResponse {
  @objc(indicatesAuthenticationNeedsRefresh:)
  override func indicatesAuthenticationNeedsRefresh(with problemDoc: TPPProblemDocument?) -> Bool {

    if super.indicatesAuthenticationNeedsRefresh(with: problemDoc) {
      return true
    }

    if statusCode == 401 {
      return true
    }

    if !isSuccess() && mimeType == "application/vnd.opds.authentication.v1.0+json" {
      return true
    }

    return false
  }
  
  /// Attempts to determine if the response indicates that the user's
  /// credentials are expired or invalid, taking into account cross-domain redirects.
  ///
  /// A 401 from a different domain than the original request does NOT indicate
  /// that our credentials are expired - it indicates a content provider issue.
  /// This prevents false "session expired" prompts when downloads are redirected
  /// to third-party CDNs that return 401.
  ///
  /// - Parameters:
  ///   - problemDoc: The problem document returned by the server.
  ///   - originalRequestURL: The URL of the original request before any redirects.
  /// - Returns: `true` if the response indicates authentication needs refresh
  ///   AND the response came from the same domain as the original request.
  func indicatesAuthenticationNeedsRefresh(
    with problemDoc: TPPProblemDocument?,
    originalRequestURL: URL?
  ) -> Bool {
    // If no original URL provided, fall back to legacy behavior
    guard let originalURL = originalRequestURL else {
      return indicatesAuthenticationNeedsRefresh(with: problemDoc)
    }
    
    // Check if response is from a different domain
    if !isSameDomain(as: originalURL) {
      Log.info(#file, "Auth check: 401 from \(self.url?.host ?? "unknown") after redirect from \(originalURL.host ?? "unknown") - third-party auth issue, not marking credentials stale")
      return false
    }
    
    return indicatesAuthenticationNeedsRefresh(with: problemDoc)
  }
}
