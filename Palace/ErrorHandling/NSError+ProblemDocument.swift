//
//  NSError+ProblemDocument.swift
//  The Palace Project
//
//  Wires NSError up to the TPPUserFriendlyError protocol (defined in the
//  PalaceNetwork package) using TPPProblemDocument (app-target type) for
//  the messaging payload. Stays in the app target because TPPProblemDocument
//  is an app-level type — moving the entire chain into PalaceNetwork would
//  require pulling Codable + RFC7807 modeling into the package, which is a
//  separate decision from the protocol split.
//

import Foundation
import PalaceNetwork

extension NSError: TPPUserFriendlyError {
    private static let problemDocumentKey = "problemDocument"

    @objc var problemDocument: TPPProblemDocument? {
        return userInfo[NSError.problemDocumentKey] as? TPPProblemDocument
    }

    /// Feeds off of the `problemDocument` computed property
    @objc public var userFriendlyTitle: String? {
        return problemDocument?.title
    }

    /// Feeds off of the `problemDocument` computed property or the localized
    /// error description.
    @objc public var userFriendlyMessage: String? {
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
}
