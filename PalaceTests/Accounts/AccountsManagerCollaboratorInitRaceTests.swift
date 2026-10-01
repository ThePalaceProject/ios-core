//
//  AccountsManagerCollaboratorInitRaceTests.swift
//
//  On cold launch the auth-document collaborators are first reached from two
//  unordered paths, and a Swift `lazy var` is not safe to initialize
//  concurrently: racing threads each build an instance. That splits
//  `AuthDocumentLoader`'s single-flight map and gives `AccountCredentialResolver`
//  two `TPPUserAccount`s for one UUID (F-034). The race window is small, so
//  `testInit_constructsCollaboratorsBeforeReturning` pins it deterministically.
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

    /// `registryLoader` stays a `lazy var` — its eight provider closures are not yet
    /// routed through `AccountsManagerOwnerRef` — so unlike the two above it cannot be
    /// asserted absent from lazy storage. What CAN be asserted, and is the property
    /// that actually matters, is that `init` has already forced its construction
    /// before returning.
    ///
    /// Why it matters: `init` registers the `.TPPUseBetaDidChange` observer, whose
    /// handler dispatches to a global queue and reaches `registryLoader` via
    /// `updateAccountSet` -> `loadCatalogs`. A Swift `lazy var` has no
    /// synchronisation, so two concurrent first-touches can both run the initialiser.
    /// The production preload used to be the only thing forcing it, and it runs AFTER
    /// the observer is registered — and the DEBUG `deferDiskCachePreloadForTesting`
    /// path (set by this suite's setUp) skips that preload entirely, so the first
    /// touch could be the background handler.
    ///
    /// This test runs with the preload deferred, which is precisely the configuration
    /// where nothing else forces construction. If it passed with the preload enabled
    /// it would be asserting the preload, not the fix.
    func testInit_forcesRegistryLoaderBeforeTheObserverCanReachIt() {
        // BOTH forcing paths must be off or this arm is vacuous:
        // `init` also calls `registryLoader.spawnInitialBackgroundLoad()`
        // (AccountsManager.swift:466) whenever `deferInitialLoadCatalogsForTesting` is
        // false. Asserting only the preload flag left the arm depending on a separate
        // flip in PalaceWiringTestCase.setUpWithError, which a future edit could remove
        // without touching this file — and the test would then pass by measuring the
        // background spawn instead of the fix.
        XCTAssertTrue(AccountsManager.deferDiskCachePreloadForTesting,
                      "vacuous without the preload deferred: the preload would force "
                      + "construction and the assertion below would prove nothing")
        XCTAssertTrue(AccountsManager.deferInitialLoadCatalogsForTesting,
                      "vacuous without the background load deferred: "
                      + "spawnInitialBackgroundLoad() is init's other first-toucher")

        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let children = Mirror(reflecting: manager).children

        // Enumerate rather than name. Neither this arm nor the two-collaborator
        // loop above would notice a NEW lazy collaborator: the loop checks a
        // hardcoded pair, this arm checks a hardcoded single, and a third
        // property would land in both blind spots. `registryLoader` is the only
        // lazy var in AccountsManager today and this pins that fact, so adding
        // another forces a deliberate decision here.
        let lazyNames = Set(children.compactMap { child -> String? in
            guard let label = child.label, label.hasPrefix("$__lazy_storage_$_") else { return nil }
            return String(label.dropFirst("$__lazy_storage_$_".count))
        })
        XCTAssertEqual(lazyNames, ["registryLoader"],
                       "AccountsManager's set of lazy vars changed. A new one is a new "
                       + "first-touch race unless init forces it too; an removed one means "
                       + "this arm should move into the stored-property loop above.")

        let storage = children.first { $0.label == "$__lazy_storage_$_registryLoader" }
        XCTAssertNotNil(storage,
                        "registryLoader is no longer a lazy var — if it became a stored "
                        + "let, fold it into testInit_constructsCollaboratorsBeforeReturning")
        if let storage {
            let value = Mirror(reflecting: storage.value)
            let isNilOptional = value.displayStyle == .optional && value.children.isEmpty
            XCTAssertFalse(isNilOptional,
                           "registryLoader was still unconstructed when init returned, so the "
                           + "TPPUseBetaDidChange handler's background first-touch can race it")
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
