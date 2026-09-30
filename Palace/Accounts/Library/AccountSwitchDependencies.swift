//
//  AccountSwitchDependencies.swift
//  Palace
//
//  Collaborators the `AccountsManager` account-switch path needs (image cache,
//  cover circuit breaker, account-state store, network executor, navigation),
//  bundled and injected so `AccountsManager` names no app-target singleton and
//  tests can observe the cleanup order with spies. The `production` binding
//  lives in `AppContainer`, the one place allowed to resolve those singletons.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

/// Frozen bundle of the account-switch cleanup collaborators, injected into
/// `AccountsManager` at construction. `Sendable` so the cleanup Task can capture it
/// by value (the pop-to-root hop must survive regardless of the manager's lifetime).
struct AccountSwitchDependencies: Sendable {
    /// Decoded-image cache. `evictDecodedImages()` runs on a real library switch
    /// (the new library has different covers); also the cache every
    /// `Account(publication:imageCache:)` the manager builds is backed by.
    let imageCache: ImageCacheType

    /// Per-uuid account load-state store. Read/written by the setter's prior-account
    /// eviction and by the hydrate / auth-doc-drive guards.
    let accountStateStore: AccountStateStore

    /// Resets the cover-fetch circuit breaker so a host that tripped while the prior
    /// library was active does not keep cover fetches suppressed for the new library.
    let resetCoverCircuitBreaker: @Sendable () -> Void

    /// Lazily resolves the shared network executor. Deferred because
    /// `AccountsManager` is constructed inside `AppContainer`'s dispatch_once;
    /// resolving the executor eagerly at init would re-enter that lock and trap.
    let networkExecutorProvider: @Sendable () -> any AccountNetworking

    /// Main-actor navigation cleanup before an account switch: pop the active
    /// navigation stack to root (when non-empty) then wait the documented settle
    /// interval before the switch's `isAccountSwitching` flag is cleared.
    let popToRootForAccountSwitch: @MainActor @Sendable () async -> Void

    init(
        imageCache: ImageCacheType,
        accountStateStore: AccountStateStore,
        resetCoverCircuitBreaker: @escaping @Sendable () -> Void,
        networkExecutorProvider: @escaping @Sendable () -> any AccountNetworking,
        popToRootForAccountSwitch: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.imageCache = imageCache
        self.accountStateStore = accountStateStore
        self.resetCoverCircuitBreaker = resetCoverCircuitBreaker
        self.networkExecutorProvider = networkExecutorProvider
        self.popToRootForAccountSwitch = popToRootForAccountSwitch
    }
}
