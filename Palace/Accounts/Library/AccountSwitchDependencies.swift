//
//  AccountSwitchDependencies.swift
//  Palace
//
//  god-class decomposition — Wave 3 seam S3.
//
//  The ambient collaborators the `AccountsManager.currentAccount` setter and its
//  `cleanupActiveContentBeforeAccountSwitch(from:to:)` path used to reach for
//  directly — the shared image cache, the shared cover-registry circuit breaker,
//  the shared account-state store, the composition root's network executor, and the
//  composition root's navigation coordinator hub. Bundled into a frozen, `Sendable`
//  deps struct injected at construction — the `RegistryExternalDependencies`
//  precedent (Wave 2b) — so that:
//
//    * a packaged `AccountsManager` (the Wave 3a `PalaceAccounts` move) names none
//      of these app-target singletons directly, and
//    * the account-switch cleanup ORDER becomes spy-observable — each seam is a
//      recordable double instead of a process-wide singleton mutation a test can
//      only observe through a `NotificationCenter` round-trip.
//
//  Provider CLOSURES preserve the LAZY resolution the originals had where the
//  original read was deferred: `networkExecutorProvider` keeps the documented
//  init-cycle deferral (the manager is built INSIDE the composition root's
//  dispatch_once, so resolving the executor eagerly at init re-enters + traps), and
//  `popToRootForAccountSwitch` keeps the `@MainActor` navigation hop.
//
//  The `production` binding lives at the composition root — the one place allowed to
//  resolve these singletons — so this file carries no edge to the container / image
//  caches / cover registry and is already the shape the 3a package move needs.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel

/// Frozen bundle of the account-switch cleanup collaborators, injected into
/// `AccountsManager` at construction. `Sendable` so the cleanup Task can capture it
/// by value (the pop-to-root hop must survive regardless of the manager's lifetime,
/// exactly as the prior composition-root-based hop did).
struct AccountSwitchDependencies: Sendable {
    /// Decoded-image cache. `evictDecodedImages()` runs on a real library switch
    /// (the new library has different covers); also the cache every
    /// `Account(publication:imageCache:)` the manager builds is backed by.
    let imageCache: ImageCacheType

    /// Per-uuid account load-state store. Read/written by the setter's prior-account
    /// eviction and by the hydrate / auth-doc-drive guards. Injected as the concrete
    /// instance for S3 (the type itself moves into `PalaceAccounts` at 3a).
    let accountStateStore: AccountStateStore

    /// Resets the cover-fetch circuit breaker so a host that tripped while the prior
    /// library was active does not keep cover fetches suppressed for the new library
    /// (was the shared cover registry's `resetHostFailures()`).
    let resetCoverCircuitBreaker: @Sendable () -> Void

    /// Lazily resolves the shared network executor. DEFERRED because `AccountsManager`
    /// is constructed inline inside `AppContainer`'s dispatch_once — resolving the
    /// executor eagerly at init would re-enter that lock and trap. Resolved once,
    /// cached behind the manager's `lazy var networkExecutor`.
    let networkExecutorProvider: @Sendable () -> TPPNetworkExecutor

    /// Main-actor navigation cleanup before an account switch: pop the active
    /// navigation stack to root (when non-empty) then wait the documented settle
    /// interval before the switch's `isAccountSwitching` flag is cleared. Encapsulates
    /// the coordinator lookup + the pop decision so the whole hop is a single spy
    /// point; the production binding resolves the coordinator via the composition root.
    let popToRootForAccountSwitch: @MainActor @Sendable () async -> Void

    init(
        imageCache: ImageCacheType,
        accountStateStore: AccountStateStore,
        resetCoverCircuitBreaker: @escaping @Sendable () -> Void,
        networkExecutorProvider: @escaping @Sendable () -> TPPNetworkExecutor,
        popToRootForAccountSwitch: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.imageCache = imageCache
        self.accountStateStore = accountStateStore
        self.resetCoverCircuitBreaker = resetCoverCircuitBreaker
        self.networkExecutorProvider = networkExecutorProvider
        self.popToRootForAccountSwitch = popToRootForAccountSwitch
    }
}
