//
//  TestAppContainerFactory.swift
//  PalaceTests
//
//  Test-only factory that builds a fresh `AppContainer` per call WITHOUT
//  mutating `AppContainer._cached`. Replaces ~14 high-concentration
//  `AppContainer.production()` test-body call sites that were silently
//  carrying state across tests through the production singleton graph.
//
//  Failure mode this seam closes
//  =============================
//  Before this factory existed, the canonical pattern for "I just need an
//  AccountsManager / downloadCenter for this test" was:
//
//      let vm = MyBooksViewModel(
//          accountsManager: AppContainer.production().accountsManager,
//          downloadCenter: AppContainer.production().downloadCenter,
//          …
//      )
//
//  Every call here reached into the process-wide cached AppContainer. Any
//  mutation a test made to the returned manager (sign-in, register an
//  account, write to UserDefaults via TPPSettings) survived into the next
//  test because the SAME manager + downloadCenter persisted across the
//  suite. The post-test observer's `_resetForTesting()` rebuild eventually
//  rebuilt the graph, but only AFTER the test completed — pollution within
//  a single test method (cross-test method, intra-class) was not closed.
//
//  This factory builds a hand-threaded graph identical in shape to
//  `AppContainer._buildCachedAppContainer()` (the production builder) but
//  isolated per test method. It deliberately mirrors that builder's
//  ordering invariants (build accountsManager BEFORE bookRegistry; build
//  authCoordinator BEFORE downloadCenter; etc.) so the value graph this
//  factory returns is byte-equivalent in topology to production. Identity
//  is the only difference — every reference is fresh.
//
//  Test-target-only. swarm_47883816 work package A.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalacePreferences
import PalaceAuth
import PalaceNetwork
@testable import Palace

/// Build a fresh `AppContainer` whose service graph is hand-threaded just
/// like the production builder, but with NO interaction with the static
/// `AppContainer._cached`. Two consecutive calls return distinct instances
/// (assertable via `===` on `accountsManager` / `bookRegistry`).
///
/// - Parameters:
///   - accountsManager: Optional explicit override. When `nil` the factory
///     constructs a fresh `AccountsManager` after pinning
///     `deferInitialLoadCatalogsForTesting = true` so the background
///     `loadCatalogs` Task is suppressed.
///   - bookRegistry: Optional explicit override. When `nil` the factory
///     constructs a fresh `TPPBookRegistry` wired to the resolved
///     `accountsManager` (the production cycle-avoidance pattern).
///
/// - Returns: A fully wired `AppContainer` distinct from
///   `AppContainer.production()`. Does NOT mutate `_cached`.
///
/// Isolation note: deliberately NOT `@MainActor` so non-actor-isolated
/// `XCTestCase` subclasses can call it from synchronous test methods. The
/// MainActor-only construction step (AuthCoordinator wiring the
/// `CoordinatorSignInModalPresenter`) hops through `MainActor.assumeIsolated`,
/// mirroring the production builder's `_buildCachedAppContainer()`. The
/// assumption is sound at runtime because XCTest test methods dispatch on
/// the main thread.
func makeTestAppContainer(
  accountsManager: AccountsManager? = nil,
  bookRegistry: TPPBookRegistryProvider? = nil
) -> AppContainer {
  // Pin the opt-out flag BEFORE constructing AccountsManager so its init
  // skips the background `loadCatalogs` Task. This mirrors the bootstrap
  // path in `PalaceTestSetup.bootstrap()` and the per-instance pin in
  // `PalaceWiringTestCase.makeFreshAccountsManager()` — without it, a
  // factory call from a test that earlier flipped the flag back to `false`
  // (e.g. `AppContainerResetTests`) would race the background fetch
  // against the test body.
  AccountsManager.deferInitialLoadCatalogsForTesting = true

  // Match `_buildCachedAppContainer()` topology byte-for-byte: executor →
  // reachability → accountsManager → imageCache/loader → bookRegistry. The
  // production builder explains the cycle-avoidance: TPPBookRegistry.init
  // takes AccountsManager as a required dependency, so manager MUST exist
  // first. Same here.
  let executor = TPPNetworkExecutor(cachingStrategy: .fallback)
  let reachability = Reachability()
  let resolvedAccountsManager = accountsManager ?? AccountsManager()
  let imageCache: ImageCacheType = ImageCache.shared
  let imageLoader: ImageLoading = ImageLoader(imageCache: imageCache)
  let resolvedBookRegistry = bookRegistry ?? TPPBookRegistry(
    accountsManager: resolvedAccountsManager,
    imageLoader: imageLoader
  )

  // Mirror the production accessibility announcer + DownloadAnnouncementService
  // pairing so MyBooksDownloadCenter receives the same announcer instance.
  let accessibilityAnnouncer = TPPAccessibilityAnnouncementCenter()
  let downloadAnnouncementService = DownloadAnnouncementService(
    announcer: accessibilityAnnouncer
  )

  // AuthCoordinator is constructed BEFORE MyBooksDownloadCenter — production
  // builder has the same order so MBDC's BookReturnService receives a
  // non-nil coordinator. The recorder + provider closures mirror the
  // production wiring. `MainActor.assumeIsolated` mirrors the production
  // builder at AppContainer.swift:402 — CoordinatorSignInModalPresenter is
  // `@MainActor`-isolated, and XCTest test methods dispatch on main so the
  // assumption is sound at runtime regardless of the call-site's static
  // isolation context.
  let authDecisionRecorder: AuthDecisionRecording = AuthDecisionRecorder()
  let authCoordinator: AuthCoordinator = MainActor.assumeIsolated {
    AuthCoordinator(
      reauthenticator: TPPReauthenticator(),
      modalPresenter: CoordinatorSignInModalPresenter(accountsManager: resolvedAccountsManager),
      userAccount: CoordinatorUserAccountAdapter(accountsManager: resolvedAccountsManager),
      accountProvider: CoordinatorAccountProvider(accountsManager: resolvedAccountsManager),
      recorder: authDecisionRecorder,
      libraryUUIDProvider: { [weak resolvedAccountsManager] in
        resolvedAccountsManager?.currentAccount?.uuid
      }
    )
  }

  let downloadCenter = MyBooksDownloadCenter(
    bookRegistry: resolvedBookRegistry,
    accountsManager: resolvedAccountsManager,
    networkExecutor: executor,
    accessibilityAnnouncements: accessibilityAnnouncer,
    downloadAnnouncementService: downloadAnnouncementService,
    reachability: reachability,
    authCoordinator: authCoordinator
  )

  // `UserAccountPublisher.shared` is `@MainActor`-isolated; resolve it via the
  // same `assumeIsolated` hop the production builder uses at
  // `AppContainer.swift:478` (XCTest dispatches on main, so the assumption is
  // sound at runtime regardless of this factory's nonisolated call site).
  let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }

  return AppContainer(
    bookRegistry: resolvedBookRegistry,
    networkExecutor: executor,
    networkQueue: NetworkQueue(transport: executor.transport, reachability: reachability),
    reachability: reachability,
    accountsManager: resolvedAccountsManager,
    settings: TPPSettings(),
    downloadCenter: downloadCenter,
    downloadAnnouncementService: downloadAnnouncementService,
    debugSettings: DebugSettings(),
    imageCache: imageCache,
    imageLoader: imageLoader,
    userAccountPublisher: userAccountPublisher,
    opdsFeedService: OPDSFeedService(),
    readerService: ReaderService(),
    navigationCoordinatorHub: NavigationCoordinatorHub(),
    tabRouterHub: AppTabRouterHub(),
    drmAuthorizerProvider: { nil },
    authCoordinator: authCoordinator
  )
}
