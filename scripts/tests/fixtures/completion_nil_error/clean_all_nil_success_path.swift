//
// clean_all_nil_success_path.swift
// Fixture: the OAuth success-path shape `completion?(nil, nil, nil)` verified
// at Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244. This is
// correct semantics — there is no failure to surface. The detector MUST NOT
// flag this; if it does, the predicate is too broad (Phase-1a-revised
// architect finding).
//

import Foundation

final class FixtureAllNilSuccess {
    var completion: ((Error?, String?, String?) -> Void)?

    func onPatronExtractionSucceeded(authToken: String, patron: [String: Any]) {
        // Success path: validateCredentials() was kicked off, no error to
        // surface, no title/message. The all-nil shape is the OAuth canon.
        completion?(nil, nil, nil)
    }
}
