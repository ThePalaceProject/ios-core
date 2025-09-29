//
//  TPPUserFriendlyError.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/15/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - TPPUserFriendlyError

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
  var userFriendlyTitle: String? { nil }
  var userFriendlyMessage: String? { nil }
}

// MARK: - NSError + TPPUserFriendlyError

extension NSError: TPPUserFriendlyError {
  private static let problemDocumentKey = "problemDocument"

  @objc var problemDocument: TPPProblemDocument? {
    userInfo[NSError.problemDocumentKey] as? TPPProblemDocument
  }

  /// Feeds off of the `problemDocument` computed property
  @objc var userFriendlyTitle: String? {
    problemDocument?.title
  }

  /// Feeds off of the `problemDocument` computed property or the localized
  /// error description.
  @objc var userFriendlyMessage: String? {
    (problemDocument?.detail ?? userInfo[NSLocalizedDescriptionKey]) as? String
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
  static func makeFromProblemDocument(
    _ problemDoc: TPPProblemDocument,
    domain: String,
    code: Int,
    userInfo: [String: Any]?
  ) -> NSError {
    var userInfo = userInfo ?? [String: Any]()
    userInfo[NSError.problemDocumentKey] = problemDoc
    return NSError(domain: domain, code: code, userInfo: userInfo)
  }
}
