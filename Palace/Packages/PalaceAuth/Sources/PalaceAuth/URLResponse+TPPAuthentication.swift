//
//  URLResponse+TPPAuthentication.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceCatalog

// MARK: - Internal mimetype/status helpers
//
// The matching `@objc isProblemDocument()` and `@objc isSuccess()` extension
// methods live in the main target's `URLResponse+NYPL.swift`. Re-declaring
// them here as `@objc` would clash on the ObjC selector at link time, so we
// keep small private helpers scoped to this file (and re-use them from the
// public methods below).

private func _isProblemDocumentMime(_ response: URLResponse) -> Bool {
    return ["application/problem+json",
            "application/api-problem+json"].contains(response.mimeType)
}

private func _isHTTPSuccess(_ response: HTTPURLResponse) -> Bool {
    return (200...299).contains(response.statusCode)
}

extension URLResponse {

    /// Attempts to determine if the response indicates that the user's
    /// credentials are expired or invalid and re-authentication should be attempted.
    ///
    /// The problem document, if available, is the primary source of truth.
    /// The server uses URL path conventions to classify auth errors:
    /// - `/auth/recoverable/*` → client should retry auth flow
    /// - `/auth/unrecoverable/*` → client should display error (re-auth won't help)
    ///
    /// - Parameter problemDoc: The problem document returned by the server.
    /// - Returns: `true` if the problem document indicates a recoverable auth error.
    @objc(indicatesAuthenticationNeedsRefresh:)
    public func indicatesAuthenticationNeedsRefresh(with problemDoc: TPPProblemDocument?) -> Bool {
        // Check for new recoverable auth error category (preferred)
        if problemDoc?.isRecoverableAuthError == true {
            return true
        }

        // Unrecoverable errors should NOT trigger re-auth
        if problemDoc?.isUnrecoverableAuthError == true {
            return false
        }

        // Backward compatibility: old credentials-invalid type from older servers
        if _isProblemDocumentMime(self) && problemDoc?.type == TPPProblemDocument.TypeInvalidCredentials {
            return true
        }

        return false
    }

    /// Checks if this response came from the same domain as the given URL.
    /// Compares base domains (e.g., palaceproject.io) rather than full hosts,
    /// so cdn.palaceproject.io and gorgon.palaceproject.io are considered the same.
    ///
    /// - Parameter otherURL: The URL to compare against.
    /// - Returns: `true` if both URLs share the same base domain.
    public func isSameDomain(as otherURL: URL) -> Bool {
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
    public static func baseDomain(from host: String) -> String {
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
    public override func indicatesAuthenticationNeedsRefresh(with problemDoc: TPPProblemDocument?) -> Bool {
        // First check problem document categories (highest priority)
        if super.indicatesAuthenticationNeedsRefresh(with: problemDoc) {
            return true
        }

        // If problem doc explicitly says unrecoverable, don't trigger re-auth
        if problemDoc?.isUnrecoverableAuthError == true {
            return false
        }

        // Fallback: bare 401 without categorized problem doc
        // (for older servers or edge cases)
        if statusCode == 401 {
            return true
        }

        // OPDS authentication document response
        if !_isHTTPSuccess(self) && mimeType == "application/vnd.opds.authentication.v1.0+json" {
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
    public func indicatesAuthenticationNeedsRefresh(
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
