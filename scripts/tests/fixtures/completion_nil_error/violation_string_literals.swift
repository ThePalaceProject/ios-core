//
// violation_string_literals.swift
// Fixture: PP-4419 / HelpSpot 17870 canonical bug shape — first arg `nil`,
// args 2-3 are string literals. Consumer's `if let error` guard suppresses
// the alert path. Detector MUST flag.
//

import Foundation

final class FixtureStringLiterals {
    var completion: ((Error?, String?, String?) -> Void)?

    func onPatronExtractionFailed() {
        // This is the PR547e185aa pre-fix shape, verbatim. The original
        // failure exits passed nil for the error. The fix wrapped them in
        // `NSError(domain: "OAuth.SignIn", code: 0, userInfo: [...])`.
        completion?(nil, "Sign In Failed", "Unable to parse authentication info")
    }
}
