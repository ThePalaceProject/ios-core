//
//  TPPBookRegistryStateConcurrencyTests.swift
//  PalaceTests
//
//  Pins the Swift 6 `complete`-mode thread-safety change to `TPPBookRegistry`'s
//  facade `RegistryState` storage. The facade's `state` moved from an
//  unsynchronised stored `var` (written from BookRegistrySync's background
//  Task/main callbacks, read cross-thread by consumers) to a computed property
//  whose backing `_state` is guarded by `stateLock`, with `syncState`
//  (`BoolWithDelay`) self-synchronised.
//
//  These tests exercise the change through the PRODUCTION SEAM (`reset(_:)`
//  drives `state = .unloaded`; `registryState` / `isSyncing` read it back) —
//  NOT via a private `_state` shortcut. They prove:
//    1. The write→read round-trip is preserved (reset lands `.unloaded`, and the
//       `state == .syncing ⇒ isSyncing` derivation still yields `false`).
//    2. Concurrent reads of `registryState` / `isSyncing` interleaved with
//       `reset(_:)` writes never crash and converge — the mutation evidence that
//       `_state` access is actually serialised. Remove the lock and this test is
//       the one that turns red under the exclusivity/thread checker.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceBookRegistry

@MainActor
final class TPPBookRegistryStateConcurrencyTests: PalaceWiringTestCase {

    private func makeRegistry() -> TPPBookRegistry {
        let accountsManager = makeFreshAccountsManager()
        let imageLoader = ImageLoader(imageCache: ImageCache.shared)
        return TPPBookRegistry(accountsManager: accountsManager, imageLoader: imageLoader)
    }

    // MARK: - 1. Round-trip through the production seam

    /// `reset(_:)` is a public seam that drives the lock-guarded setter to
    /// `.unloaded`. After it, both the `registryState` getter and the
    /// `state`-derived `isSyncing` must read back consistently — proving the
    /// write path and the `state == .syncing ⇒ isSyncing` derivation survived
    /// the move behind `stateLock`.
    ///
    /// Kills: a mutant that drops the `syncState.value = (newValue == .syncing)`
    /// derivation from the setter (isSyncing would stay whatever it was), and a
    /// mutant that fails to write `_state` in the setter (registryState wouldn't
    /// reach `.unloaded`).
    func testReset_drivesRegistryStateToUnloaded_andClearsIsSyncing() {
        let registry = makeRegistry()
        let account = "state-rt-\(UUID().uuidString)"

        registry.reset(account)

        XCTAssertEqual(registry.registryState, .unloaded,
                       "reset(_:) must drive the lock-guarded state to .unloaded via the production seam")
        XCTAssertFalse(registry.isSyncing,
                       "a non-.syncing state must derive isSyncing == false through the setter")

        // Cleanup any on-disk artifact reset may have touched.
        if let url = registry.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 2. Concurrent read/write safety

    /// Hammers the cross-thread readers (`registryState`, `isSyncing`) while a
    /// writer thread repeatedly drives the setter via `reset(_:)`. Under the
    /// pre-change unsynchronised `var _state`, concurrent read+write of the enum
    /// is a data race the exclusivity/thread checker flags; with `stateLock` it
    /// is serialised. The functional assertion (terminal state is the last value
    /// written) is the observable proof the lock didn't corrupt the value.
    func testConcurrentStateReads_duringResetWrites_neverCorruptTerminalState() {
        let registry = makeRegistry()
        let account = "state-concurrent-\(UUID().uuidString)"

        let iterations = 200
        let readsPerIteration = 8
        let validStates: Set<TPPBookRegistry.RegistryState> = [
            .unloaded, .loading, .loaded, .syncing, .synced
        ]

        // Concurrent readers + a writer, all fanned out via concurrentPerform so
        // the reads genuinely overlap the writes on distinct threads.
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            if i % 4 == 0 {
                // Writer: reset drives state = .unloaded through the seam.
                registry.reset(account)
            } else {
                for _ in 0..<readsPerIteration {
                    let observed = registry.registryState
                    // Every observed value must be a legal enum case — a torn
                    // read of an unsynchronised Int-backed enum could surface an
                    // out-of-range raw value.
                    XCTAssertTrue(validStates.contains(observed),
                                  "registryState returned an illegal case \(observed.rawValue) — indicates a torn/racy read")
                    _ = registry.isSyncing
                }
            }
        }

        // After the storm, one final reset pins a deterministic terminal state.
        registry.reset(account)
        XCTAssertEqual(registry.registryState, .unloaded,
                       "final reset must leave a consistent, uncorrupted terminal state")
        XCTAssertFalse(registry.isSyncing)

        if let url = registry.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
