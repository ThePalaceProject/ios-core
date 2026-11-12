//
//  DownloadCenterSignInRoute.swift
//  Palace
//
//  Where `MyBooksDownloadCenter` sends its sign-in prompts (PP-5545).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension MyBooksDownloadCenter {
    /// Presents the sign-in sheet for the current account. The container that
    /// builds this center binds it to its own presenter
    /// (`AppContainer.routeDownloadCenterSignIn()`); the default reads the
    /// production container only when called, never during init.
    var presentSignInForCurrentAccount: @MainActor (_ completion: (() -> Void)?) -> Void {
        get { signInRoute.present }
        set { signInRoute.present = newValue }
    }
}

/// Holds the closure above, so the sign-in paths the center builds in `init`
/// call whatever is bound when they run, not what was bound at construction.
/// `@unchecked Sendable`: `present` is only read and written under `lock`.
final class DownloadCenterSignInRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var _present: @MainActor (_ completion: (() -> Void)?) -> Void = { completion in
        AppContainer.production().signInModalSheetPresenter
            .presentSignInModalForCurrentAccount(completion: completion)
    }

    var present: @MainActor (_ completion: (() -> Void)?) -> Void {
        get { lock.withLock { _present } }
        set { lock.withLock { _present = newValue } }
    }
}
