//
// clean_with_synthesized_nserror.swift
// Fixture: the CANONICAL fix from commit 547e185aa. Error arg is an
// `NSError(domain: "OAuth.SignIn", code: 0, userInfo: [...])` instead of nil.
// Consumer's `if let error` guard succeeds and the alert path runs.
// Detector MUST NOT flag.
//

import Foundation

final class FixtureSynthesizedNSError {
    var completion: ((Error?, String?, String?) -> Void)?

    func onPatronExtractionFailed() {
        let error = NSError(
            domain: "OAuth.SignIn",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Unable to parse authentication info"]
        )
        completion?(error, "Sign In Failed", "Unable to parse authentication info")
    }
}
