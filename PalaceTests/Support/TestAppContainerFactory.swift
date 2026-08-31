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
import PalaceBookModel
import PalaceBookRegistry

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

  // PP-4957: force the LCP-audiobook-streaming flag OFF for the test download
  // center. `MyBooksDownloadCenter.contentPresence` consults this provider, and
  // its production default reads `RemoteFeatureFlags.shared` — a global whose
  // value in the test host is non-deterministic (FirebaseManager init state +
  // `.standard` + parallel ordering). Pinning it OFF keeps every reconcile /
  // download-first test deterministic (the pre-PP-4957 behavior they assert);
  // streaming tests opt IN by setting the provider on their own instance.
  downloadCenter.lcpStreamingEnabledProvider = { false }

  // `UserAccountPublisher.shared` is `@MainActor`-isolated; resolve it via the
  // same `assumeIsolated` hop the production builder uses at
  // `AppContainer.swift:478` (XCTest dispatches on main, so the assumption is
  // sound at runtime regardless of this factory's nonisolated call site).
  let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }

  // Created eagerly: SQLite cannot open a database under a directory that does
  // not exist, and a failed connection would silently turn every queued write
  // into a reported drop rather than a stored row.
  func makeIsolatedQueueDirectory() -> String {
    let dir = NSTemporaryDirectory() + "test-queue-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  // PP-5022 — the two hubs are one unit: the navigation hub resolves "which
  // stack is on screen" by asking this router which tab is selected. A test
  // container that pairs a router-less hub with a live router is exactly the
  // pre-fix state (`hub.coordinator` degrades to last-registered), so any
  // future test of visible-tab resolution written through this factory could
  // only ever be green.
  let tabRouterHub = AppTabRouterHub()

  return AppContainer(
    bookRegistry: resolvedBookRegistry,
    networkExecutor: executor,
    // Per-container temp store, never the app's real `simplified.db`. PP-4987
    // made the offline branch reachable, so any test touching this container
    // now writes DURABLE rows into Application Support that a later
    // reachability event can replay as live POSTs. The credential provider is
    // stubbed out for the same reason: the default reaches the keychain.
    networkQueue: NetworkQueue(
      transport: executor.transport,
      reachability: reachability,
      databaseDirectory: makeIsolatedQueueDirectory(),
      authorizationHeaderProvider: { _ in nil }
    ),
    reachability: reachability,
    accountsManager: resolvedAccountsManager,
    settings: TPPSettings(),
    featureFlags: RemoteFeatureFlags.shared,
    downloadCenter: downloadCenter,
    downloadAnnouncementService: downloadAnnouncementService,
    debugSettings: DebugSettings(),
    imageCache: imageCache,
    imageLoader: imageLoader,
    userAccountPublisher: userAccountPublisher,
    opdsFeedService: OPDSFeedService(),
    readerService: ReaderService(),
    navigationCoordinatorHub: NavigationCoordinatorHub(tabRouterHub: tabRouterHub),
    tabRouterHub: tabRouterHub,
    drmAuthorizerProvider: { nil },
    authCoordinator: authCoordinator
  )
}
