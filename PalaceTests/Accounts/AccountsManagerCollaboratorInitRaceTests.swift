//
//  AccountsManagerCollaboratorInitRaceTests.swift
//  PalaceTests
//
//  `AccountsManager` is `@unchecked Sendable` and not actor-isolated, and on a cold
//  launch its auth-document collaborator is first reached from two unordered paths:
//  the slim-hydrate `DispatchQueue.main.async` drive and the detached background
//  `loadCatalogs`. A Swift `lazy var` is not safe to initialize concurrently: each
//  racing thread can build its own instance, and all but one are dropped. For
//  `AuthDocumentLoader` that splits the per-UUID single-flight map (duplicate fetches,
//  and a dropped instance's `[weak self]` completion skips its terminal state write);
//  for `AccountCredentialResolver` it yields two `TPPUserAccount` instances for one
//  library UUID, which is the F-034 invariant the resolver exists to hold.
//
//  These tests drive concurrent FIRST access on a freshly constructed manager and
//  assert the observable single-instance property. The race window is small, so the
//  dynamic tests are backed by `testInit_constructsCollaboratorsBeforeReturning`,
//  which fails deterministically if either collaborator goes back to a `lazy var`.
//

import XCTest
@testable import Palace

final class AccountsManagerCollaboratorInitRaceTests: PalaceWiringTestCase {

    private static let rounds = 25
    private static let threadsPerRound = 16

    private var savedDeferDiskPreload = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip the on-disk catalog preload: these tests never read `accountSets`, and a
        // fast construction keeps many rounds per test affordable.
        savedDeferDiskPreload = AccountsManager.deferDiskCachePreloadForTesting
        AccountsManager.deferDiskCachePreloadForTesting = true
    }

    override func tearDownWithError() throws {
        AccountsManager.deferDiskCachePreloadForTesting = savedDeferDiskPreload
        try super.tearDownWithError()
    }

    /// Lock-guarded collector for values produced on `concurrentPerform` workers.
    private final class Collected<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T] = []
        func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: - AuthDocumentLoader

    /// Every thread's single-flight claim, made during concurrent first access, must be
    /// visible afterwards. If first access builds more than one loader, the claims that
    /// landed in a dropped instance vanish — which in production is a duplicate
    /// auth-document fetch for the same account.
    func testConcurrentFirstAccess_authDocSingleFlightClaims_allLandInOneLoader() {
        for round in 0..<Self.rounds {
            let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
            let uuids = (0..<Self.threadsPerRound).map { "urn:uuid:race-\(round)-\($0)" }

            DispatchQueue.concurrentPerform(iterations: uuids.count) { i in
                manager._seedInflightAuthDocForTesting(uuid: uuids[i], age: 1)
            }

            let missing = uuids.filter { !manager._inflightAuthDocContainsForTesting(uuid: $0) }
            XCTAssertEqual(missing, [],
                           "round \(round): single-flight claims lost to a second AuthDocumentLoader instance")
            if !missing.isEmpty { return }
        }
    }

    // MARK: - AccountCredentialResolver

    /// Concurrent first resolution of one library UUID must yield ONE `TPPUserAccount`
    /// (F-034). Two resolver instances would each mint their own.
    func testConcurrentFirstAccess_userAccountForOneLibrary_returnsOneInstance() {
        for round in 0..<Self.rounds {
            let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
            let uuid = "urn:uuid:race-credential-\(round)"
            let collected = Collected<TPPUserAccount>()

            DispatchQueue.concurrentPerform(iterations: Self.threadsPerRound) { _ in
                collected.append(manager.userAccount(for: uuid))
            }

            let distinct = Set(collected.values.map { ObjectIdentifier($0) })
            XCTAssertEqual(collected.values.count, Self.threadsPerRound)
            XCTAssertEqual(distinct.count, 1,
                           "round \(round): \(distinct.count) TPPUserAccount instances for one library UUID")
            if distinct.count != 1 { return }
        }
    }

    // MARK: - Deterministic guard

    /// Both collaborators must already exist when `init` returns, so no caller can race
    /// their construction. A `lazy var` reflects as `$__lazy_storage_$_<name>` holding
    /// `nil` until first access; a stored property reflects under its own name.
    func testInit_constructsCollaboratorsBeforeReturning() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let children = Mirror(reflecting: manager).children

        for name in ["authDocLoader", "credentialResolver"] {
            XCTAssertFalse(children.contains { $0.label == "$__lazy_storage_$_\(name)" },
                           "\(name) is a lazy var: its first access can race")
            let stored = children.first { $0.label == name }
            XCTAssertNotNil(stored, "\(name) is not a stored property of AccountsManager")
            if let stored {
                let value = Mirror(reflecting: stored.value)
                let isNilOptional = value.displayStyle == .optional && value.children.isEmpty
                XCTAssertFalse(isNilOptional, "\(name) is nil after init returned")
            }
        }
    }

    // MARK: - Owner reference

    /// The collaborators hold the owner box and the manager holds the collaborators, so
    /// the box must not retain the manager: a strong reference here is a cycle that
    /// keeps every `AccountsManager` alive.
    func testOwnerRef_doesNotKeepItsObjectAlive() {
        let ref = LockedWeakRef<NSObject>()
        autoreleasepool {
            let object = NSObject()
            ref.manager = object
            withExtendedLifetime(object) {}
        }
        XCTAssertNil(ref.manager, "the owner box kept its object alive after the last owner released it")
    }

    /// Unbound (or deallocated) owner: the loader must treat itself as torn down, so a
    /// completion arriving after the manager is gone writes no account state.
    func testTornDownProbe_withNoManager_reportsTornDown() {
        let probe = AccountsManager.tornDownProbe(AccountsManagerOwnerRef())
        XCTAssertTrue(probe())
    }

    func testTornDownProbe_withLiveManager_reportsTornDownOnlyAfterCancel() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let owner = AccountsManagerOwnerRef()
        owner.manager = manager
        let probe = AccountsManager.tornDownProbe(owner)

        XCTAssertFalse(probe(), "a live manager that was never cancelled is not torn down")
        manager.cancelBackgroundWork()
        XCTAssertTrue(probe(), "cancelBackgroundWork() must mark the loader torn down")
    }
}
