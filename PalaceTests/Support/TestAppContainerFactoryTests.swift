//
//  TestAppContainerFactoryTests.swift
//  PalaceTests
//
//  Behavioural contract tests for `makeTestAppContainer()` — the test-only
//  factory introduced by swarm_47883816 work package A. The factory MUST:
//
//   1. Return a fresh AppContainer per call (NOT cached) — distinct
//      `accountsManager` references across consecutive calls.
//   2. Leave the production `AppContainer._cached` graph untouched, so a
//      test that drives the factory does not poison a subsequent test
//      that reads `AppContainer.production()`.
//   3. Set `AccountsManager.deferInitialLoadCatalogsForTesting = true`
//      BEFORE constructing AccountsManager so the factory-minted manager
//      does not spawn the background `loadCatalogs` Task that polluted
//      cross-test state in swarm_4b64e4e0.
//   4. Accept explicit `accountsManager` / `bookRegistry` overrides so
//      wiring-case subclasses can hand in pre-configured collaborators.
//
//  Test-target-only. swarm_47883816 work package A.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class TestAppContainerFactoryTests: XCTestCase {

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
  /// accounts to disk mid-test (the swarm_4b64e4e0 failure mode). Observable
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
}
