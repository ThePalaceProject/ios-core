//  TestAppContainerFactoryTests.swift
//
//  Contract for the test-only `makeTestAppContainer()`: each call returns a new
//  container (distinct `accountsManager`); `AppContainer._cached` is untouched;
//  `deferInitialLoadCatalogsForTesting` is set before AccountsManager is built,
//  so no background `loadCatalogs` leaks across tests; explicit
//  `accountsManager` / `bookRegistry` overrides are honored.

import XCTest
@testable import Palace
import PalaceBookRegistry
import PalaceCatalog

// Subclasses `PalaceTestCase` (WS-0 / M0): `testMakeTestAppContainer_doesNot…`
// sets `AccountsManager.deferInitialLoadCatalogsForTesting = false` (restored
// via `defer`), so per `RuntimeQuiescenceLintTests` it MUST adopt the
// quiescence base. The `defer` restores the flag before tearDown, so the
// inherited assert passes.
@MainActor
final class TestAppContainerFactoryTests: PalaceTestCase {

  override func tearDown() {
    super.tearDown()
  }

  // MARK: - Behaviour 1: fresh instance per call

  /// Two consecutive `makeTestAppContainer()` calls MUST hand back containers
  /// whose `accountsManager` references are NOT identical. If the factory
  /// silently cached its output, every test that constructed a container would
  /// inherit the prior test's state — defeating the entire purpose of the
  /// isolation seam. Asserting against `accountsManager` rather than the
  /// struct value itself because the struct is a value type and `===` doesn't
  /// apply; the manager is the canonical reference-typed marker of identity.
  func testMakeTestAppContainer_returnsDistinctInstancesPerCall() {
    let first = makeTestAppContainer()
    let second = makeTestAppContainer()
    XCTAssertFalse(
      first.accountsManager === second.accountsManager,
      "Factory must vend a fresh AccountsManager per call — caching would re-introduce the cross-test pollution this seam exists to eliminate"
    )
    XCTAssertFalse(
      first.bookRegistry as AnyObject === second.bookRegistry as AnyObject,
      "Factory must vend a fresh TPPBookRegistry per call — registry state (cached books, state) MUST NOT leak between tests"
    )
  }

  // MARK: - Behaviour 2: production cache untouched

  /// The production graph is the byte-identical contract every UI code path
  /// resolves via `EnvironmentValues().appContainer`. Tests that build their
  /// own container via the factory MUST NOT disturb that cache — otherwise
  /// `AppContainer.production()` would silently switch personalities mid-run.
  /// Snapshot the production `accountsManager` reference before and after a
  /// factory call; they must be `===` identical.
  func testMakeTestAppContainer_doesNotMutateProductionCache() {
    let pre = AppContainer.production().accountsManager
    _ = makeTestAppContainer()
    let post = AppContainer.production().accountsManager
    XCTAssertTrue(
      pre === post,
      "AppContainer.production().accountsManager identity must survive a factory call — the factory MUST NOT rewrite _cached"
    )
  }

  // MARK: - Behaviour 3: defer flag fires before AccountsManager init

  /// `AccountsManager.deferInitialLoadCatalogsForTesting = true` is the gate
  /// that prevents the background `loadCatalogs` Task from spawning at init.
  /// Without this gate the factory-minted manager would write 1142+ bundled
  /// accounts to disk mid-test. Observable
  /// proof: after the factory call, the new manager's
  /// `backgroundFetchTaskHandleForTesting` (the canonical observation seam
  /// from AccountsManagerCancellationTests) is `nil` — meaning the init's
  /// `Task.detached { loadCatalogs }` branch was never taken.
  func testMakeTestAppContainer_doesNotSpawnLoadCatalogsTask() {
    // Force the production flag to false first so we can prove the factory
    // sets it back to true synchronously inside its closure. Restore on exit.
    let priorFlag = AccountsManager.deferInitialLoadCatalogsForTesting
    AccountsManager.deferInitialLoadCatalogsForTesting = false
    defer { AccountsManager.deferInitialLoadCatalogsForTesting = priorFlag }

    let container = makeTestAppContainer()

    XCTAssertTrue(
      container.accountsManager._backgroundFetchTaskHandleIsNil,
      "Factory-minted AccountsManager MUST NOT have spawned the background loadCatalogs Task — the defer flag must fire before AccountsManager() runs"
    )
  }

  // MARK: - Behaviour 4: explicit override wiring

  /// A wiring-case subclass that already owns an `AccountsManager` (via
  /// `PalaceWiringTestCase.makeFreshAccountsManager()`) must be able to hand
  /// that manager to the factory. The returned container's `accountsManager`
  /// MUST be the injected instance, not a freshly-minted one. Mirrors the
  /// substitution contract `AppContainerTests.testInit_withMockBookRegistry_*`
  /// pins for the production `init`.
  func testMakeTestAppContainer_acceptsExplicitDependencyOverrides() {
    AccountsManager.deferInitialLoadCatalogsForTesting = true
    let explicitManager = AccountsManager()
    defer { explicitManager.cancelBackgroundWork() }
    let container = makeTestAppContainer(accountsManager: explicitManager)
    XCTAssertTrue(
      container.accountsManager === explicitManager,
      "Factory MUST hand back the injected AccountsManager, not a freshly-minted one — override seam is load-bearing for wiring-case subclasses"
    )
  }

  /// Symmetric override coverage for `bookRegistry`. Substituting a mock
  /// registry is the canonical way to inject controlled state for a single
  /// test method; the override MUST flow through to the returned container.
  func testMakeTestAppContainer_acceptsBookRegistryOverride() {
    let explicitRegistry = TPPBookRegistryMock()
    let container = makeTestAppContainer(bookRegistry: explicitRegistry)
    XCTAssertTrue(
      container.bookRegistry as AnyObject === explicitRegistry,
      "Factory MUST hand back the injected bookRegistry, not a freshly-minted one"
    )
  }

  /// An injected defaults suite must back the manager the factory builds, so a
  /// test that seeds a current account through it writes
  /// `TPPCurrentAccountIdentifier` into that suite and not into
  /// `UserDefaults.standard` — which on a simulator is the app's own container,
  /// where a leftover fixture uuid leaves the app with no resolvable library.
  func testMakeTestAppContainer_injectedDefaults_backTheManagerItBuilds() {
    let isolated = Self.testUserDefaults()
    let manager = makeTestAppContainer(defaults: isolated).accountsManager
    defer { manager.cancelBackgroundWork() }
    let standardBefore = UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
    let uuid = "factory-defaults-\(UUID().uuidString)"

    let restore = manager._seedAccountForTesting(stubAccount(uuid: uuid))
    defer { restore() }

    XCTAssertEqual(isolated.string(forKey: currentAccountIdentifierKey), uuid,
                   "the seed must land in the injected suite")
    XCTAssertEqual(UserDefaults.standard.string(forKey: currentAccountIdentifierKey), standardBefore,
                   "the seed must not reach UserDefaults.standard")
  }

  /// The decisive test for PP-5411: a caller that passes NO `defaults:` must
  /// still keep the seed out of `UserDefaults.standard`. Isolation used to be
  /// opt-in, and 247 call sites took the `.standard` default, so a fixture uuid
  /// that outlived its test decided which library the app opened next on that
  /// simulator. Restore the `.standard` default and this test fails.
  func testMakeTestAppContainer_defaultDefaults_keepSeedOutOfStandard() {
    let manager = makeTestAppContainer().accountsManager
    defer { manager.cancelBackgroundWork() }
    let standardBefore = UserDefaults.standard.string(forKey: currentAccountIdentifierKey)
    let uuid = "factory-default-\(UUID().uuidString)"

    let restore = manager._seedAccountForTesting(stubAccount(uuid: uuid))
    defer { restore() }

    XCTAssertEqual(manager.currentAccountId, uuid,
                   "the seed must still reach the manager the factory built")
    XCTAssertEqual(UserDefaults.standard.string(forKey: currentAccountIdentifierKey), standardBefore,
                   "a container built without an explicit defaults suite must not write the app's own container")
  }

  /// The default is a per-call expression, not one shared suite. Two containers
  /// that shared a store would let one test read the library another seeded,
  /// which is the cross-test pollution the factory exists to prevent.
  func testMakeTestAppContainer_defaultDefaults_areDistinctPerCall() {
    let first = makeTestAppContainer().accountsManager
    let second = makeTestAppContainer().accountsManager
    defer { first.cancelBackgroundWork(); second.cancelBackgroundWork() }

    let restore = first._seedAccountForTesting(stubAccount(uuid: "distinct-\(UUID().uuidString)"))
    defer { restore() }

    XCTAssertNotNil(first.currentAccountId, "the seed must land in the first container's store")
    XCTAssertNil(second.currentAccountId,
                 "a second container must not see the first one's selected library")
  }

  /// The device's own selected library must not reach a test container. Writing
  /// the key into `.standard` and then building a container with the default
  /// store pins that: under the old `.standard` default the manager read the
  /// device's uuid, which is what made `seedAccountIfNeeded` take its "use the
  /// existing library" branch on some simulators and the fixture branch on
  /// others. Isolated, that helper always seeds a fixture.
  func testMakeTestAppContainer_defaultDefaults_ignoreTheDeviceSelectedLibrary() {
    let original = UserDefaults.standard.object(forKey: currentAccountIdentifierKey)
    defer {
      if let original {
        UserDefaults.standard.set(original, forKey: currentAccountIdentifierKey)
      } else {
        UserDefaults.standard.removeObject(forKey: currentAccountIdentifierKey)
      }
    }
    let deviceLibrary = "device-library-\(UUID().uuidString)"
    UserDefaults.standard.set(deviceLibrary, forKey: currentAccountIdentifierKey)

    let manager = makeTestAppContainer().accountsManager
    defer { manager.cancelBackgroundWork() }

    XCTAssertNil(manager.currentAccountId,
                 "a test container must not inherit the library the device has selected")
    XCTAssertNil(manager.currentAccount,
                 "so seedAccountIfNeeded takes its fixture branch whatever the device holds")
  }

  /// Isolating the default cannot cost one resetter per container. The reset
  /// registry never drops entries and every test boundary drives all of them, so
  /// a resetter per call would make cleanup quadratic in the number of containers
  /// a run builds — and the factory is reached from hundreds of call sites.
  func testMakeTestAppContainer_defaultDefaults_shareOneResetter() {
    let before = Set(SingletonResetRegistry.shared.registeredNames())
    let pendingBefore = isolatedTestUserDefaultsPendingPurgeCount()

    let first = makeTestAppContainer().accountsManager
    let second = makeTestAppContainer().accountsManager
    let third = makeTestAppContainer().accountsManager
    defer {
      first.cancelBackgroundWork()
      second.cancelBackgroundWork()
      third.cancelBackgroundWork()
    }

    let added = Set(SingletonResetRegistry.shared.registeredNames()).subtracting(before)
    XCTAssertTrue(added.isSubset(of: ["isolatedTestUserDefaults"]),
                  "three containers must add at most the one shared resetter, not one each. Added: \(added)")
    XCTAssertEqual(isolatedTestUserDefaultsPendingPurgeCount() - pendingBefore, 3,
                   "and that one resetter must have all three suites to purge")
  }

  /// The shared resetter must actually wipe the suites it tracks, or isolating the
  /// default would trade a leak into the app's own container for an unbounded pile
  /// of test suites on disk. Drives the factory's default-argument helper directly,
  /// since that is what every call site evaluates.
  func testIsolatedTestUserDefaults_areWipedByTheSharedResetter() {
    let suite = isolatedTestUserDefaults()
    suite.set("present", forKey: "purge-probe")
    XCTAssertEqual(suite.string(forKey: "purge-probe"), "present",
                   "precondition: the value is in the isolated suite")

    XCTAssertTrue(SingletonResetRegistry.shared.registeredNames().contains("isolatedTestUserDefaults"),
                  "the purge must be wired to the reset registry, or nothing ever calls it")
    isolatedTestUserDefaultsPurgeForTesting()

    XCTAssertNil(suite.string(forKey: "purge-probe"),
                 "the purge must drop the suite's persistent domain")
  }

  private func stubAccount(uuid: String) -> Account {
    let publication = OPDS2Publication(
      links: [OPDS2Link(href: "https://example.com/catalog", rel: "http://opds-spec.org/catalog")],
      metadata: OPDS2Publication.Metadata(id: uuid, title: "Factory Fixture"),
      images: nil
    )
    return Account(publication: publication, imageCache: MockImageCache())
  }

  /// An injected executor must reach the container (and so the network
  /// queue's transport); otherwise a test's stubbed session is bypassed.
  func testMakeTestAppContainer_acceptsNetworkExecutorOverride() {
    let explicitExecutor = TPPNetworkExecutor(cachingStrategy: .fallback)
    let container = makeTestAppContainer(networkExecutor: explicitExecutor)
    XCTAssertTrue(container.networkExecutor === explicitExecutor,
                  "Factory MUST hand back the injected network executor")
    XCTAssertFalse(makeTestAppContainer().networkExecutor === explicitExecutor,
                   "Without an override the factory MUST build its own executor")
  }
}
