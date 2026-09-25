//
//  AccountsManagerOwnerRef.swift
//  Palace
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Weak back-reference from `AccountsManager`'s collaborators to the manager that
/// owns them.
///
/// The collaborators' provider closures need the manager, but a closure cannot
/// capture `self` before `super.init()`. Holding them as `lazy var`s deferred
/// construction to first access, and first access happens concurrently on a cold
/// launch (the main-queue slim-hydrate drive and the detached background
/// `loadCatalogs`). Concurrent `lazy var` initialization builds more than one
/// instance and races the write to the backing storage. Routing the closures
/// through this box lets `init` build every collaborator as a `let` before
/// `super.init()`, then bind the manager once, before any of them can run.
///
/// Reads before the bind (and after the manager is deallocated) return `nil`,
/// which matches the `[weak self]` closures this replaces. The lock makes the
/// bind-then-read ordering explicit rather than relying on the init sequence.
final class AccountsManagerOwnerRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _manager: AccountsManager?

    var manager: AccountsManager? {
        get { lock.lock(); defer { lock.unlock() }; return _manager }
        set { lock.lock(); defer { lock.unlock() }; _manager = newValue }
    }
}
