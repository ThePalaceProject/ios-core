//
//  TestAppContainerFactory.swift
//  PalaceTests
//
//  Test-only factory that builds a fresh `AppContainer` per call WITHOUT
//  touching `AppContainer._cached`, so state a test writes through its
//  managers (sign-in, accounts, TPPSettings defaults) cannot reach the next
//  test via the shared production graph. Mirrors the ordering invariants of
//  `AppContainer._buildCachedAppContainer()` (accountsManager BEFORE
//  bookRegistry, authCoordinator BEFORE downloadCenter, …) so the topology
//  matches production; only identity differs. Test-target-only.
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

/// Suite names handed out by `TestContainerDefaults.make()` that have not been
/// purged yet, drained by a single resetter.
///
/// One registry entry, not one per call. `SingletonResetRegistry` never drops
/// entries and `PalaceSingletonResetObserver` calls `invokeAll()` at every test
/// boundary, so registering a resetter per suite would make cleanup quadratic in
/// the number of containers the run builds — and since PP-5411 every
/// `makeTestAppContainer()` call builds one. `register(_:resetter:)` replaces an
/// entry with the same name, so re-registering on each call keeps exactly one.
///
/// `@unchecked Sendable` invariant: the only mutable state is `pending`, read and
/// written exclusively under `lock`. `purge()` takes the names under the lock and
/// then releases it before touching the stores, so a slow `removePersistentDomain`
/// does not block a concurrent `track`.
private final class IsolatedDefaultsSuites: @unchecked Sendable {
  static let shared = IsolatedDefaultsSuites()
  private let lock = NSLock()
  private var pending: [String] = []

  func track(_ suiteName: String) {
    lock.lock()
    pending.append(suiteName)
    lock.unlock()
    SingletonResetRegistry.shared.register("isolatedTestUserDefaults") {
      IsolatedDefaultsSuites.shared.purge()
    }
  }

  func purge() {
    lock.lock()
    let names = pending
    pending.removeAll()
    lock.unlock()
    for name in names {
      // Wipes the whole suite; `removeObject(forKey:)` would clear only the keys
      // we know about and leak any the test set that we do not.
      UserDefaults.standard.removePersistentDomain(forName: name)
      UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }
  }

  /// Suite names awaiting a purge. Exposed so the factory's own suite can assert
  /// that one resetter covers many containers.
  var pendingCount: Int {
    lock.lock(); defer { lock.unlock() }
    return pending.count
  }

  /// Drop every suite tracked so far, leaving no state behind for the next test.
  /// This holder keeps a list across test boundaries, so it owes the same reset
  /// contract as any other shared singleton in the test bundle.
  static func resetShared() {
    shared.purge()
  }
}

/// Test-only namespace for the isolated `UserDefaults` suites the factory hands
/// out.
///
/// Grouped rather than left as bundle-global functions: `purgeForTesting()` drops
/// live stores, and a free function with that effect is reachable from every
/// suite in the bundle, where an accidental call would wipe another test's
/// defaults mid-run.
enum TestContainerDefaults {

  /// A fresh suite for one `makeTestAppContainer()` call, wiped at the test
  /// boundary.
  ///
  /// This is the factory's `defaults:` default, and a default argument
  /// expression is evaluated at each call site, so every container gets its own
  /// store. Kept separate from `XCTestCase.testUserDefaults()`, which registers
  /// one resetter per call: that is fine for a helper a test calls by hand a few
  /// times, but the factory is reached from hundreds of call sites on every run.
  static func make() -> UserDefaults {
    let suiteName = "test-container-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      // Falling back to `.standard` would write the app's own container, which
      // is the leak this default exists to close, so fall back to another
      // isolated suite and let the caller's assertions speak for themselves.
      return UserDefaults(suiteName: "test-container-fallback-\(UUID().uuidString)") ?? .standard
    }
    IsolatedDefaultsSuites.shared.track(suiteName)
    return defaults
  }

  /// Suites awaiting a purge, so the factory's own suite can assert that one
  /// resetter covers many containers.
  static var pendingPurgeCount: Int {
    IsolatedDefaultsSuites.shared.pendingCount
  }

  /// Run the purge the registered resetter runs. The factory's own suite drives
  /// this rather than `SingletonResetRegistry.invokeAll()`, which would also
  /// fire every bootstrap resetter mid-test and leave the host part-reset.
  static func purgeForTesting() {
    IsolatedDefaultsSuites.resetShared()
  }
}

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
///   - networkExecutor: Optional explicit override, e.g. an executor whose
///     session routes through a test `URLProtocol`. When `nil` the factory
///     constructs a fresh `.fallback` executor.
///   - defaults: backing store for the manager the factory builds when
///     `accountsManager` is `nil`. A fresh isolated suite per call by default,
///     so a test that seeds a current account or sets `currentAccount` writes
///     `TPPCurrentAccountIdentifier` into that suite. The default used to be
///     `.standard`, which on a simulator is the app's own container, so a
///     fixture uuid that outlived its test left the app with no resolvable
///     library (PP-5411). A manager built this way starts with an empty
///     registry, so `currentAccount` reads `nil` until the test seeds one.
///     Pass `.standard` only to assert against the app's own container, and
///     declare the file in the `UserDefaultsIsolationLintTests` whitelist.
///     Ignored when `accountsManager` is supplied, since that manager carries
///     its own store.
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
  bookRegistry: TPPBookRegistryProvider? = nil,
  networkExecutor: TPPNetworkExecutor? = nil,
  defaults: UserDefaults = TestContainerDefaults.make()
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
  let executor = networkExecutor ?? TPPNetworkExecutor(cachingStrategy: .fallback)
  let reachability = Reachability()
  let resolvedAccountsManager = accountsManager ?? AccountsManager(defaults: defaults)
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
  // builder `_buildCachedAppContainer()` — CoordinatorSignInModalPresenter is
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
    authCoordinator: authCoordinator,
    // Sign-out through a test container must not reach the app-wide offline queue.
    offlineActionRemover: { _ in }
  )

  // PP-4957: force the LCP-audiobook-streaming flag OFF for the test download
  // center. `MyBooksDownloadCenter.contentPresence` consults this provider, and
  // its production default reads `RemoteFeatureFlags.shared` — a global whose
  // value in the test host is non-deterministic (FirebaseManager init state +
  // `.standard` + parallel ordering). Pinning it OFF keeps every reconcile /
  // download-first test deterministic (the pre-PP-4957 behavior they assert);
  // streaming tests opt IN by setting the provider on their own instance.
  downloadCenter.lcpStreamingEnabledProvider = { false }

  let downloadNetworkLossMonitor = MainActor.assumeIsolated {
    AppContainer.makeDownloadNetworkLossMonitor(for: downloadCenter)
  }

  // `UserAccountPublisher.shared` is `@MainActor`-isolated; resolve it via the
  // same `assumeIsolated` hop `_buildCachedAppContainer()` uses (XCTest
  // dispatches on main, so the assumption is sound at runtime regardless of
  // this factory's nonisolated call site).
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
    authCoordinator: authCoordinator,
    downloadNetworkLossMonitor: downloadNetworkLossMonitor
  )
}
