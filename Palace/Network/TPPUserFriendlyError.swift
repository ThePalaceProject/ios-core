//
//  TPPUserFriendlyError.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/15/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceCatalog

/// A protocol describing an error that MAY offer user friendly
/// messaging to the user.
protocol TPPUserFriendlyError: Error {
    /// A short summary of the error, if available.
    var userFriendlyTitle: String? { get }

    /// A user-friendly short message describing the error in more detail,
    /// if possible.
    var userFriendlyMessage: String? { get }
}

// Dummy implementation merely to ease error reporting work upstream, where
// it's very common to have to handle errors obtained in various ways. This
// is also ok because user friendly strings are in general never guaranteed
// to be there, even when we obtain a problem document.
extension TPPUserFriendlyError {
    var userFriendlyTitle: String? { return nil }
    var userFriendlyMessage: String? { return nil  }
}

extension NSError: TPPUserFriendlyError {
    private static let problemDocumentKey = "problemDocument"

    @objc var problemDocument: TPPProblemDocument? {
        return userInfo[NSError.problemDocumentKey] as? TPPProblemDocument
    }

    /// Feeds off of the `problemDocument` computed property
    @objc var userFriendlyTitle: String? {
        return problemDocument?.title
    }

    /// Feeds off of the `problemDocument` computed property or the localized
    /// error description.
    @objc var userFriendlyMessage: String? {
        return (problemDocument?.detail ?? userInfo[NSLocalizedDescriptionKey]) as? String
    }

    /// Builds an NSError using the given problem document for its user-friendly
    /// messaging.
    /// - Parameters:
    ///   - problemDoc: The problem document per RFC7807.
    ///   - domain: The domain to give to the error being created.
    ///   - code: The code to give to the error being created.
    ///   - userInfo: The user friendly messaging will be appended to this
    ///   dictionary.
    /// - Returns: A new NSError with the ProblemDocument `title` and `detail`.
    static func makeFromProblemDocument(_ problemDoc: TPPProblemDocument,
                                        domain: String,
                                        code: Int,
                                        userInfo: [String: Any]?) -> NSError {
        var userInfo = userInfo ?? [String: Any]()
        userInfo[NSError.problemDocumentKey] = problemDoc
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }

    /// Builds an NSError from a non-2xx HTTP response, embedding any RFC 7807
    /// problem document found in the body so downstream UI layers (e.g.
    /// `userFacingSignInError`) can surface the server-supplied title/detail
    /// instead of a generic fallback like "Invalid Credentials".
    ///
    /// Use this anywhere you would otherwise call
    /// `NSError(domain:code:userInfo:)` for an HTTP error response — calling
    /// it consistently is what keeps token-auth, basic-auth, and SAML flows
    /// honoring the same contract toward `userFacingSignInError`.
    static func makeFromHTTPResponse(data: Data,
                                     statusCode: Int,
                                     domain: String,
                                     userInfo: [String: Any]? = nil) -> NSError {
        if let problemDoc = TPPProblemDocument.fromProblemResponseData(data) {
            return makeFromProblemDocument(problemDoc,
                                           domain: domain,
                                           code: statusCode,
                                           userInfo: userInfo)
        }
        return NSError(domain: domain, code: statusCode, userInfo: userInfo)
    }
}
