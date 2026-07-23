//
//  TPPBookRegistryFacadeContractTests.swift
//  PalaceTests
//
//  PR-W2-pre (god-class decomposition Wave 2) — the facade dependency
//  call-order contract for `TPPBookRegistry`. This pins the CURRENT behavior of
//  the facade's per-mutation seams BEFORE the Wave-2b `AccountScopeProviding`
//  inversion rewrites the class, so that inversion can be proven
//  behavior-preserving: after 2b, this file must stay green with its assertions
//  untouched.
//
//  WHAT THIS PINS (the two facade-owned seams the 2b rewrite touches):
//
//    1. The `imageLoader` dependency call-order — WHICH mutations trigger a
//       thumbnail fetch, and for WHICH book:
//         · addBook            → fetches the ADDED book's thumbnail
//         · removeBook         → fetches the REMOVED book's thumbnail
//         · updateAndRemoveBook→ fetches the book's thumbnail
//         · setState / updateBook(no-op) / setFulfillmentId → NEVER fetch
//       Recorded through an injected `ImageLoading` spy into a `CallLog`, then
//       asserted inline (no external snapshot baseline — green on first CI run).
//
//    2. The `bookStatePublisher` per-mutation emission sequence — the (id, state)
//       tuple each mutation broadcasts (or, for state-preserving updateBook /
//       setFulfillmentId, that it broadcasts NOTHING).
//
//  These two seams are exactly what the 2b inversion rewrites (the init pair and
//  the `accountsManager.currentAccount?.uuid` capture sites route through here).
//  The publisher-emission drop mutant and any change to which book gets a
//  thumbnail fetch are the specific regressions 2b could introduce silently;
//  this file is the net.
//
//  SCOPE NOTE — the on-disk save half of each mutation is account-gated
//  (`if let account = accountsManager.currentAccount?.uuid { save }`) and there
//  is NO facade-level seam to make `currentAccount` non-nil in a unit test
//  without loading the catalog graph (the setter needs a real `Account` and has
//  global-singleton side effects). See the `// SEAM:` note below. The disk layer is
//  already covered directly at the BookRegistrySync/BookRegistryStore level by
//  TPPBookRegistryPersistenceTests (save round-trip, account isolation,
//  corruption). The facade-level account-capture flip test (PP-4129) is a
//  REQUIRED new test in PR-W2b, enabled by the `AccountScopeProviding` stub.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import UIKit
@testable import Palace

@MainActor
final class TPPBookRegistryFacadeContractTests: PalaceWiringTestCase {

    // `cancellables` is inherited from PalaceWiringTestCase and drained on
    // tearDown; the base is a `*TestCase` so this class is exempt from
    // TearDownRequiredLint by inheritance. We touch no global-singleton or
    // defaults state — every registry is a fresh local instance backed by a
    // helper-minted AccountsManager (cancelled on tearDown by the base).

    override func tearDownWithError() throws {
        // No hermetic on-disk registry to remove: every mutation's `save` is
        // account-gated and `currentAccount` is nil here (catalog load
        // deferred), so nothing was ever written to disk. The base drains
        // `cancellables` and cancels helper-minted managers.
        try super.tearDownWithError()
    }

    // MARK: - Spy: records the facade → imageLoader thumbnail fetches

    /// `ImageLoading` test double that records every thumbnail fetch into a
    /// thread-safe `CallLog`. Only the `thumbnailImage` surface the facade
    /// actually drives is recorded; everything else is an inert no-op / nil so
    /// constructing it boots nothing.
    private final class SpyImageLoader: ImageLoading {
        let log = CallLog()

        func coverImage(for book: TPPBook) async -> UIImage? { nil }
        func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage? { nil }
        func playerCoverImage(for book: TPPBook) async -> UIImage? { nil }

        func thumbnailImage(for book: TPPBook) async -> UIImage? {
            log.record("thumbnailImage", args: ["book": book.identifier, "style": "async"])
            return nil
        }

        func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
            completion(nil)
        }

        func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void) {
            log.record("thumbnailImage", args: ["book": book.identifier, "style": "completion"])
            completion(nil)
        }

        func get(for key: String) -> UIImage? { nil }
        func getAsync(for key: String) async -> UIImage? { nil }
        func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?) {}
        func remove(for key: String) {}
        func clearAll() {}
        func evictDecodedImages() {}
        func warmMemoryCache(for keys: [String]) async {}
    }

    // MARK: - Harness

    private func makeRegistry(_ spy: SpyImageLoader) -> TPPBookRegistry {
        // No configured currentAccount (helper-minted, catalog load deferred) →
        // the account-gated `save` closures are skipped, so no lazy
        // AppContainer provider is ever resolved. Every mutation's imageLoader
        // fetch + publisher emission still fire — they are account-independent.
        TPPBookRegistry(
            accountsManager: makeFreshAccountsManager(),
            imageLoader: spy
        )
    }

    /// Subscribes to the facade's per-book state stream, filtered to a single
    /// identifier so seed/other-book noise cannot corrupt the recorded sequence
    /// (bookStatePublisher is a PassthroughSubject — no replay — but filtering
    /// keeps the assertion robust against unrelated emissions).
    private func collectStates(
        from registry: TPPBookRegistry,
        for identifier: String,
        into sink: @escaping (TPPBookState) -> Void
    ) {
        registry.bookStatePublisher
            .filter { $0.0 == identifier }
            .sink { sink($0.1) }
            .store(in: &cancellables)
    }

    /// Deterministic join: drain the store's write barrier (every mutation block
    /// + its onComplete has run and scheduled its main-queue re-broadcast), then
    /// flush one main-queue hop so the `.receive(on: RunLoop.main)` publisher
    /// emissions have been delivered to our sink. No wall-clock wait.
    private func settle(_ registry: TPPBookRegistry) async {
        await registry._awaitPendingWritesForTesting()
        await drainMainQueueAsync()
    }

    // MARK: - 1. addBook

    /// addBook fetches the ADDED book's thumbnail exactly once and broadcasts the
    /// initial state. Kills: dropping `imageLoader.thumbnailImage(for: book)` at
    /// the top of addBook; dropping the `bookStateSubject.send((id, state))`
    /// re-broadcast; or hard-coding the emitted state to the default instead of
    /// the caller-supplied `.downloading`.
    func testAddBook_fetchesAddedBookThumbnail_andEmitsInitialState() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-add-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id, title: "Add")

        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        registry.addBook(book, state: .downloading)
        await settle(registry)

        XCTAssertEqual(spy.log.snapshot().map(\.method), ["thumbnailImage"],
                       "addBook must fetch a thumbnail exactly once")
        XCTAssertEqual(spy.log.snapshot().first?.args["book"], id,
                       "addBook must fetch the ADDED book's thumbnail")
        XCTAssertEqual(emitted, [.downloading],
                       "addBook must broadcast (id, state) exactly once with the caller-supplied state")
    }

    // MARK: - 2. setState

    /// A legal setState broadcasts the new state and fetches NO thumbnail. Kills:
    /// dropping the setState `bookStateSubject.send`; and any mutant that adds a
    /// spurious thumbnail fetch to the setState path (the facade's setState is
    /// image-agnostic).
    func testSetState_emitsNewState_withoutFetchingThumbnail() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-setstate-\(UUID().uuidString)"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "SetState"),
                         state: .downloadNeeded)
        await settle(registry)

        spy.log.reset()
        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        // .downloadNeeded → .downloading is a legal transition (no illegal
        // handler / assertionFailure).
        registry.setState(.downloading, for: id)
        await settle(registry)

        XCTAssertTrue(spy.log.snapshot().isEmpty,
                      "setState must not fetch a thumbnail")
        XCTAssertEqual(emitted, [.downloading],
                       "setState must broadcast exactly one (id, newState) event")
    }

    // MARK: - 3. removeBook

    /// removeBook broadcasts `.unregistered` and fetches the REMOVED book's
    /// thumbnail (the facade re-fetches to refresh any stale cover cell). Kills:
    /// dropping the `.unregistered` re-broadcast; emitting a non-`.unregistered`
    /// terminal state; dropping the removed-book thumbnail fetch; or fetching a
    /// different book than the one removed.
    func testRemoveBook_emitsUnregistered_andFetchesRemovedBookThumbnail() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-remove-\(UUID().uuidString)"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "Remove"),
                         state: .downloadNeeded)
        await settle(registry)

        spy.log.reset()
        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        registry.removeBook(forIdentifier: id)
        await settle(registry)

        XCTAssertEqual(spy.log.snapshot().map(\.method), ["thumbnailImage"],
                       "removeBook must fetch the removed book's thumbnail exactly once")
        XCTAssertEqual(spy.log.snapshot().first?.args["book"], id,
                       "removeBook must fetch the REMOVED book's thumbnail")
        XCTAssertEqual(emitted, [.unregistered],
                       "removeBook must broadcast (id, .unregistered) exactly once")
    }

    // MARK: - 4. updateAndRemoveBook (CLAUDE.md return-path contract)

    /// updateAndRemoveBook fetches the book's thumbnail and broadcasts
    /// `.unregistered`. This pins the return-path contract that the network
    /// revoke flow uses `updateAndRemoveBook` (update-then-remove), distinct from
    /// the plain `removeBook` cleanup path. Kills: dropping the thumbnail fetch;
    /// emitting a terminal state other than `.unregistered`.
    func testUpdateAndRemoveBook_fetchesThumbnail_andEmitsUnregistered() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-updateremove-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id, title: "UpdateRemove")
        registry.addBook(book, state: .downloadNeeded)
        await settle(registry)

        spy.log.reset()
        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        registry.updateAndRemoveBook(book)
        await settle(registry)

        XCTAssertEqual(spy.log.snapshot().map(\.method), ["thumbnailImage"],
                       "updateAndRemoveBook must fetch the book's thumbnail exactly once")
        XCTAssertEqual(spy.log.snapshot().first?.args["book"], id)
        XCTAssertEqual(emitted, [.unregistered],
                       "updateAndRemoveBook must broadcast (id, .unregistered) exactly once")
    }

    // MARK: - 5. updateBook (state-preserving)

    /// A state-preserving updateBook broadcasts NOTHING and fetches no thumbnail.
    /// Kills the `nextState != previousState` → `==` (or dropped-guard) mutant on
    /// the updateBook emission, and any spurious thumbnail fetch added to the
    /// updateBook path.
    func testUpdateBook_statePreserving_doesNotEmit_norFetchThumbnail() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-update-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id, title: "Update")
        registry.addBook(book, state: .holding)
        await settle(registry)

        spy.log.reset()
        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        registry.updateBook(book) // .holding → .holding: no state change
        await settle(registry)

        XCTAssertTrue(spy.log.snapshot().isEmpty,
                      "a state-preserving updateBook must not fetch a thumbnail")
        XCTAssertTrue(emitted.isEmpty,
                      "a state-preserving updateBook must not broadcast a per-book state event")
    }

    // MARK: - 6. setFulfillmentId

    /// setFulfillmentId records a fulfillment id without broadcasting a per-book
    /// state event and without fetching a thumbnail. Kills a mutant that routes
    /// setFulfillmentId through the state-broadcast path (it must be silent on
    /// bookStatePublisher).
    ///
    // SEAM: the on-disk effect of setFulfillmentId (and of every mutation above)
    // is gated on `accountsManager.currentAccount?.uuid` being non-nil, which a
    // unit test cannot arrange without loading the catalog graph. The persisted
    // `fulfillmentId` present-on-disk assertion the spec names is therefore
    // deferred to PR-W2b, where an injected `AccountScopeProviding` stub supplies
    // a fixed `currentAccountID` (the same seam that enables the PP-4129
    // account-capture flip test). The disk layer itself is already pinned by
    // TPPBookRegistryPersistenceTests via BookRegistrySync/BookRegistryStore.
    func testSetFulfillmentId_doesNotEmitPerBookState_norFetchThumbnail() async {
        let spy = SpyImageLoader()
        let registry = makeRegistry(spy)
        let id = "facade-fulfill-\(UUID().uuidString)"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "Fulfill"),
                         state: .downloadNeeded)
        await settle(registry)

        spy.log.reset()
        var emitted: [TPPBookState] = []
        collectStates(from: registry, for: id) { emitted.append($0) }

        let fulfillmentId = "ff-\(UUID().uuidString)"
        registry.setFulfillmentId(fulfillmentId, for: id)
        await settle(registry)

        XCTAssertTrue(spy.log.snapshot().isEmpty,
                      "setFulfillmentId must not fetch a thumbnail")
        XCTAssertTrue(emitted.isEmpty,
                      "setFulfillmentId must not broadcast a per-book state event")
        XCTAssertEqual(registry.fulfillmentId(forIdentifier: id), fulfillmentId,
                       "setFulfillmentId must store the id in the registry (in-memory effect, account-independent) — kills a dropped store.setFulfillmentId mutant")
    }
}
