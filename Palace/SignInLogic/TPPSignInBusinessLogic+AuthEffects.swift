//
//  TPPSignInBusinessLogic+AuthEffects.swift
//  The Palace Project
//

import Foundation
import PalaceAuth

extension TPPSignInBusinessLogic {

    /// Starts the work `AuthReducer` planned for the action just dispatched.
    ///
    /// The effect runs on a sign-in task: detached and never cancelled in
    /// production, joinable under XCTest. `.none` starts no task. The
    /// environment holds `self` strongly because validation is meant to finish
    /// after the sign-in screen goes away; it lives only as long as the task.
    func runAuthEffect(_ effect: PalaceAuth.Effect<AuthAction, AuthEnvironment>) {
        guard !effect.isNone else { return }
        let environment = AuthEnvironment(validateCredentials: { await self.validateCredentials() })
        // AuthReducer's effects report through this object, never through a
        // follow-up action.
        startSignInTask { _ = await effect.run(environment) }
    }
}
