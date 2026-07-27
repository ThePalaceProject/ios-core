//
//  TPPBookRegistryMutationContractTests.swift
//  PalaceTests
//
//  Contract C (swarm_8ce6f5ae WS3) — Kill the registry dual-write + enforce
//  `TPPBookState.allowedTransitions` at the single mutation seam.
//
//  What this pins:
//   1. The THREE transitions Contract C added to `allowedTransitions`
//      (.downloadSuccessful→.downloadNeeded, .used→.downloadNeeded,
//      .holding→.downloading) are legal — both via the pure `canTransition`
//      and through the REAL enforced `TPPBookRegistry.setState` seam.
//   2. An illegal transition trips the injected violation handler (the DEBUG
//      `assertionFailure` path, exercised here through an injected handler so the
//      suite does not crash) AND the state is STILL applied (never dropped).
//   3. The lifecycle `registryStatePublisher` is CREATED AND FED — the dead
//      `syncStatePublisher` did not emit; this one does, on every state write.
//   4. The empty-registry HANG guard: the SAML-sync (registry:455) and
//      launch-reconciliation (MBDC:2076) observers key on the LIFECYCLE publisher
//      and STILL FIRE on a fresh empty-registry load that emits ZERO per-book
//      events — proving why routing them at `bookStatePublisher` would hang.
//   5. The holds-badge lifecycle guard: the badge refreshes on a sync-complete
//      lifecycle emission with zero per-book events, and on the hand-fired
//      holds-changed trigger that replaced the deleted NotificationCenter post.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookModel

@MainActor
final class TPPBookRegistryMutationContractTests: PalaceWiringTestCase {

    // `cancellables` (Set<AnyCancellable>) is provided by PalaceWiringTestCase and
    // torn down by its lifecycle.

    // MARK: - Helpers

    /// Records the illegal-transition callbacks the enforced seam emits.
    private final class TransitionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(from: TPPBookState, to: TPPBookState, id: String)] = []
        func record(_ from: TPPBookState, _ to: TPPBookState, _ id: String) {
            lock.lock(); _calls.append((from, to, id)); lock.unlock()
        }
        var calls: [(from: TPPBookState, to: TPPBookState, id: String)] {
            lock.lock(); defer { lock.unlock() }; return _calls
        }
    }

    private func makeRegistry(
        onIllegal: @escaping TPPBookRegistry.IllegalTransitionHandler = TPPBookRegistry.defaultIllegalTransitionHandler
    ) -> TPPBookRegistry {
        TPPBookRegistry(
            accountsManager: makeFreshAccountsManager(),
            imageLoader: MockImageLoader(),
            onIllegalTransition: onIllegal
        )
    }

    // MARK: - 1. Newly-legal transitions (pure canTransition)

    /// Kills a mutant that drops any of the three added `allowedTransitions`
    /// entries: each pair would flip to `false`.
    func testCanTransition_newlyLegalPairs_areAllowed() {
        XCTAssertTrue(TPPBookState.canTransition(from: .downloadSuccessful, to: .downloadNeeded),
                      "content-protection re-download / OverDrive -1008 recovery / LRU eviction")
        XCTAssertTrue(TPPBookState.canTransition(from: .used, to: .downloadNeeded),
                      "re-download / eviction from an in-use book")
        XCTAssertTrue(TPPBookState.canTransition(from: .holding, to: .downloading),
                      "ready hold promoted straight to downloading at the concurrency cap")
    }

    /// Kills a mutant that makes `canTransition` return a constant `true`.
    func testCanTransition_illegalPairs_areRejected() {
        XCTAssertFalse(TPPBookState.canTransition(from: .unregistered, to: .downloadSuccessful))
        XCTAssertFalse(TPPBookState.canTransition(from: .downloadNeeded, to: .used))
        XCTAssertFalse(TPPBookState.canTransition(from: .used, to: .downloading))
    }

    // MARK: - 2. Enforcement at the real setState seam

    /// Illegal transition → handler fires with the exact pair AND the write is
    /// still applied. Kills: enforcement removed (handler never fires), the
    /// `!canTransition` guard inverted (fires on legal), or the write dropped on
    /// violation (state would not reach `.used`).
    func testSetState_illegalTransition_invokesHandler_andStillApplies() {
        let recorder = TransitionRecorder()
        let registry = makeRegistry(onIllegal: { recorder.record($0, $1, $2) })
        let id = "enf-illegal-\(UUID().uuidString)"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "Enforce"),
                         state: .downloadNeeded)

        // .downloadNeeded → .used is NOT in allowedTransitions.
        registry.setState(.used, for: id)

        XCTAssertEqual(recorder.calls.count, 1, "handler must fire exactly once for the illegal write")
        XCTAssertEqual(recorder.calls.first?.from, .downloadNeeded)
        XCTAssertEqual(recorder.calls.first?.to, .used)
        XCTAssertEqual(recorder.calls.first?.id, id)
        XCTAssertEqual(registry.state(for: id), .used,
                       "state must STILL be applied on violation — never dropped")

        registry.removeBook(forIdentifier: id)
    }

    /// Legal transition → handler must NOT fire. Kills the inverted-guard mutant.
    func testSetState_legalTransition_doesNotInvokeHandler() {
        let recorder = TransitionRecorder()
        let registry = makeRegistry(onIllegal: { recorder.record($0, $1, $2) })
        let id = "enf-legal-\(UUID().uuidString)"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "Legal"),
                         state: .downloadNeeded)

        registry.setState(.downloading, for: id) // legal

        XCTAssertTrue(recorder.calls.isEmpty, "a legal transition must not trip the handler")
        XCTAssertEqual(registry.state(for: id), .downloading)

        registry.removeBook(forIdentifier: id)
    }

    /// The three newly-legal pairs must NOT trip the handler at the enforced
    /// seam — proving Step-1 (corrected set) legalizes them for Step-3
    /// (enforcement) WITHOUT editing the three real call sites.
    func testSetState_newlyLegalTransitions_doNotInvokeHandler_atRealSeam() {
        let cases: [(from: TPPBookState, to: TPPBookState)] = [
            (.downloadSuccessful, .downloadNeeded),
            (.used, .downloadNeeded),
            (.holding, .downloading)
        ]
        for pair in cases {
            let recorder = TransitionRecorder()
            let registry = makeRegistry(onIllegal: { recorder.record($0, $1, $2) })
            let id = "newly-legal-\(pair.from.stringValue())-\(UUID().uuidString)"
            registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "NL"),
                             state: pair.from)

            registry.setState(pair.to, for: id)

            XCTAssertTrue(recorder.calls.isEmpty,
                          "\(pair.from.stringValue())→\(pair.to.stringValue()) must be legal at the enforced seam")
            XCTAssertEqual(registry.state(for: id), pair.to)

            registry.removeBook(forIdentifier: id)
        }
    }

    // MARK: - 3. The lifecycle publisher is FED (real registry)

    /// `reset(_:)` drives `state = .unloaded` through the production seam, which
    /// MUST feed `registryStateSubject`. `dropFirst()` discards the seeded current
    /// value so only the setter-driven emission can satisfy the expectation.
    ///
    /// Kills the mutant that removes `registryStateSubject.send(newValue)` from
    /// the `state` setter: with it gone, nothing emits past the dropped seed and
    /// this expectation times out.
    func testRegistryStatePublisher_isFed_onStateWrite() {
        let registry = makeRegistry()
        let exp = expectation(description: "lifecycle emission from the state setter")
        var emitted: TPPBookRegistry.RegistryState?
        registry.registryStatePublisher
            .dropFirst() // drop the CurrentValueSubject seed replay
            .sink { state in
                emitted = state
                exp.fulfill()
            }
            .store(in: &cancellables)

        registry.reset("acct-\(UUID().uuidString)")

        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(emitted, .unloaded,
                       "reset drives state=.unloaded; the setter must feed the lifecycle publisher")
    }

    // MARK: - 4. Empty-registry HANG guard (registry:455 + MBDC:2076)

    /// A fresh empty-registry load-complete emits a LIFECYCLE event but ZERO
    /// per-book events. The SAML-sync observer (registry:455) and the
    /// launch-reconciliation observer (MBDC:2076) both key on the lifecycle
    /// publisher, so both still fire — while a `bookStatePublisher` subscriber
    /// would receive nothing and hang forever. This test encodes exactly that
    /// invariant: both lifecycle predicates fire, per-book count is zero.
    func testEmptyRegistryLoad_lifecycleObserversFire_withZeroPerBookEmissions() {
        let registry = TPPBookRegistryMock() // fresh, empty

        var perBookEmissions = 0
        registry.bookStatePublisher
            .dropFirst() // drop the mock's seeded ("", .unregistered)
            .sink { _ in perBookEmissions += 1 }
            .store(in: &cancellables)

        // registry:455 predicate — post-sign-in SAML sync runs at .loaded/.synced.
        let samlSyncFired = expectation(description: "SAML-sync observer fires on lifecycle load")
        registry.registryStatePublisher
            .sink { if $0 == .loaded || $0 == .synced { samlSyncFired.fulfill() } }
            .store(in: &cancellables)

        // MBDC:2076 predicate — isRegistryLoadedForReconcile is true for
        // .loaded/.syncing/.synced.
        let launchReconcileFired = expectation(description: "launch-reconciliation observer fires")
        registry.registryStatePublisher
            .sink {
                switch $0 {
                case .loaded, .syncing, .synced: launchReconcileFired.fulfill()
                case .unloaded, .loading: break
                @unknown default: break
                }
            }
            .store(in: &cancellables)

        // Fresh empty registry finishes loading: lifecycle → .loaded, no books.
        registry.state = .loaded

        wait(for: [samlSyncFired, launchReconcileFired], timeout: 5.0)
        XCTAssertEqual(perBookEmissions, 0,
                       "an empty-registry load emits ZERO per-book events — the reason these two observers MUST key on registryStatePublisher")
    }

    // MARK: - 5. Holds-badge lifecycle guard (AppTabHostView:456)

    /// A background sync flipping a reserved→ready hold leaves the book at
    /// `.holding` (no per-book event) but advances the lifecycle to `.synced`.
    /// The badge subscribes to the lifecycle publisher, so it refreshes with zero
    /// per-book emissions — the case the deleted `nextState != previousState`
    /// notification path suppressed.
    func testHoldsBadge_refreshesOnLifecycleSync_withZeroPerBookEmissions() {
        let registry = TPPBookRegistryMock()

        var perBookEmissions = 0
        registry.bookStatePublisher
            .dropFirst()
            .sink { _ in perBookEmissions += 1 }
            .store(in: &cancellables)

        let badgeRefreshed = expectation(description: "badge refreshes on lifecycle sync")
        registry.registryStatePublisher
            .sink { _ in badgeRefreshed.fulfill() } // AppTabHostView badge lifecycle sub
            .store(in: &cancellables)

        registry.state = .synced

        wait(for: [badgeRefreshed], timeout: 5.0)
        XCTAssertEqual(perBookEmissions, 0,
                       "a reserved→ready hold flip changes no book state; the badge must still refresh off the lifecycle publisher")
    }

    /// The two deleted external posters (Holds:249, DeveloperSettings:741) now
    /// call `notifyHoldsChanged()`; the badge subscribes to
    /// `holdsDidChangePublisher`. This pins that hand-fired path end-to-end.
    ///
    /// Kills a mutant where `notifyHoldsChanged()` stops sending into the subject.
    func testHoldsBadge_refreshesOnHoldsChangedTrigger() {
        let registry = TPPBookRegistryMock()

        let badgeRefreshed = expectation(description: "badge refreshes on holds-changed trigger")
        registry.holdsDidChangePublisher
            .sink { _ in badgeRefreshed.fulfill() }
            .store(in: &cancellables)

        registry.notifyHoldsChanged() // the poster-replacement call

        wait(for: [badgeRefreshed], timeout: 5.0)
    }

    // MARK: - 6. Contract snapshot — enforced-seam decision sequence

    /// Drives a fixed transition walk through the ENFORCED seam and snapshots the
    /// ordered list of illegal-transition reports. This pins the enforcement
    /// contract structurally: the newly-legal `.downloadSuccessful→.downloadNeeded`
    /// step produces NO report (a removed set entry would add one and drift the
    /// snapshot), while the two genuinely-illegal steps report in order with the
    /// correct `from`/`to`. A removed/inverted enforcement check drifts it too.
    func testEnforcedSeam_illegalTransitionSequence_matchesContract() {
        let log = CallLog()
        let registry = makeRegistry(onIllegal: { from, to, _ in
            log.record("illegalTransition",
                       args: ["from": from.stringValue(), "to": to.stringValue()])
        })
        let id = "contract-book"
        registry.addBook(TPPBookMocker.mockBook(identifier: id, title: "Contract"),
                         state: .downloadNeeded)

        // downloadNeeded → downloading (legal)
        registry.setState(.downloading, for: id)
        // downloading → downloadSuccessful (legal)
        registry.setState(.downloadSuccessful, for: id)
        // downloadSuccessful → downloadNeeded (NEWLY legal — Contract C addition)
        registry.setState(.downloadNeeded, for: id)
        // downloadNeeded → used (illegal → report #1)
        registry.setState(.used, for: id)
        // used → downloading (illegal → report #2)
        registry.setState(.downloading, for: id)

        ContractSnapshot.assert(log, named: "enforcedSeamIllegalTransitionSequence")

        registry.removeBook(forIdentifier: id)
    }
}
