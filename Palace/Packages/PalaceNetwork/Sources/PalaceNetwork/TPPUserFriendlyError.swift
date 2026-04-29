//
//  TPPUserFriendlyError.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 7/15/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//
//  Pure protocol declaration — has no app-target dependencies, lives in
//  PalaceNetwork so package-level error-handling code (NYPLResult, request
//  executors) can refer to it. The NSError extension that wires the
//  protocol up to TPPProblemDocument lives in the app target as
//  `NSError+ProblemDocument.swift` because it depends on TPPProblemDocument.
//

import Foundation

/// A protocol describing an error that MAY offer user friendly
/// messaging to the user.
public protocol TPPUserFriendlyError: Error {
    /// A short summary of the error, if available.
    var userFriendlyTitle: String? { get }

    /// A user-friendly short message describing the error in more detail,
    /// if possible.
    var userFriendlyMessage: String? { get }
}

// Default implementation provided so it's always safe to access these
// properties even when the conforming type doesn't override them. User
// friendly strings are never guaranteed to be present, even when we
// have a problem document.
public extension TPPUserFriendlyError {
    var userFriendlyTitle: String? { return nil }
    var userFriendlyMessage: String? { return nil }
}
