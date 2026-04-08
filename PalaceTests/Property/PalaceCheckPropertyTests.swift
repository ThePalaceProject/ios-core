//
//  PalaceCheckPropertyTests.swift
//  PalaceTests
//
//  Initial property-based test suite for Palace using PalaceCheck.
//

import XCTest
import Foundation
@testable import Palace

final class PalaceCheckPropertyTests: XCTestCase {

    // MARK: - BookButtonMapper.map is total

    func test_BookButtonMapper_map_isTotal_forAllStates() {
        // Property: for every (TPPBookState, isProcessing) combination,
        // BookButtonMapper.map returns *some* BookButtonState without crashing.
        // We exhaustively iterate the state enum (small) and randomize availability.
        forAll(50, seed: 0xB00C, name: "BookButtonMapper.map total") { (state: TPPBookState, isProcessing: Bool) in
            let availabilities: [TPPOPDSAcquisitionAvailability?] = [
                nil,
                TPPOPDSAcquisitionAvailabilityUnlimited(),
                TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 1, copiesTotal: 1),
                TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 1, copiesTotal: 5, since: nil, until: nil),
                TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 2, copiesTotal: 5, since: nil, until: nil),
                TPPOPDSAcquisitionAvailabilityReady(since: nil, until: nil)
            ]
            for availability in availabilities {
                _ = BookButtonMapper.map(
                    registryState: state,
                    availability: availability,
                    isProcessingDownload: isProcessing
                )
                // If we got here, no crash. The function returns non-Optional, so totality is established
                // by the absence of a crash.
            }
            return true
        }
    }

    // MARK: - TPPBook dictionary round-trip

    func test_TPPBook_dictionaryRoundTrip() {
        forAll(50, seed: 0xB001, name: "TPPBook dictionary round-trip") { (arb: ArbBook) in
            let dict = arb.book.dictionaryRepresentation()
            guard let restored = TPPBook(dictionary: dict) else { return false }
            // TPPBook is not Equatable; compare stable identifying fields.
            return restored.identifier == arb.book.identifier
                && restored.title == arb.book.title
        }
    }

    // MARK: - Backoff delay sequence is non-negative & monotone

    /// PROPERTY-GAP: TPPNetworkExecutor does not expose a public retry-delay
    /// sequence — its retry path is integrated with token-refresh and an actor
    /// queue. We exercise the *contract* expected of any backoff sequence by
    /// modeling exponential backoff locally and asserting the property.
    /// When TPPNetworkExecutor is refactored to expose `delays(forAttempts:base:)`,
    /// swap the implementation under test.
    func test_BackoffDelay_isNonNegativeAndMonotone() {
        func exponentialBackoff(base: Double, attempts: Int, cap: Double = 60.0) -> [Double] {
            (0..<attempts).map { i in min(cap, base * pow(2.0, Double(i))) }
        }
        forAll(100, seed: 0xB0FF, name: "backoff non-negative & monotone non-decreasing") { (rawBase: Int, rawAttempts: Int) in
            let base = max(0.001, Double(abs(rawBase) % 50) + 0.001)
            let attempts = max(1, abs(rawAttempts) % 12)
            let delays = exponentialBackoff(base: base, attempts: attempts)
            if delays.contains(where: { $0 < 0 }) { return false }
            for i in 1..<delays.count where delays[i] < delays[i - 1] { return false }
            return true
        }
    }

    // MARK: - OPDS2Publication JSON round-trip

    func test_OPDS2Publication_jsonRoundTrip() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        forAll(100, seed: 0xB002, name: "OPDS2Publication JSON round-trip") { (pub: OPDS2Publication) in
            do {
                let data = try encoder.encode(pub)
                let restored = try decoder.decode(OPDS2Publication.self, from: data)
                return restored == pub
            } catch {
                return false
            }
        }
    }

    // MARK: - TPPBookState transition table
    //
    // SEAM-VERIFIED: TPPBookState now exposes `allowedTransitions` and
    // `canTransition(from:to:)`. Properties below pin that contract.
    // The table is documentation-only at the registry layer (setState does
    // not yet enforce it), but it is the canonical contract.

    func test_TPPBookState_validSequencesRespectTable() {
        // Property: a random walk that only traverses edges from the allowed
        // transitions set must always satisfy `canTransition` at every step.
        forAll(100, seed: 0xB003, name: "TPPBookState sequences respect transition table") { (seedState: TPPBookState) in
            var rng = PalaceCheckRNG(seed: 0xABCD &+ UInt64(seedState.rawValue))
            var current = seedState
            for _ in 0..<8 {
                let neighbors = TPPBookState.allowedTransitions
                    .filter { $0.from == current }
                    .map { $0.to }
                guard !neighbors.isEmpty else { break }
                let next = neighbors[Int(rng.next() % UInt64(neighbors.count))]
                if !TPPBookState.canTransition(from: current, to: next) { return false }
                current = next
            }
            return true
        }
    }

    func test_TPPBookState_selfTransitionsAlwaysAllowed() {
        // Idempotent re-set must be a no-op: every state must self-transition.
        for state in TPPBookState.allCases {
            XCTAssertTrue(TPPBookState.canTransition(from: state, to: state),
                          "self-transition rejected for \(state)")
        }
    }

    func test_TPPBookState_unregisteredToDownloadingAllowed() {
        // Auto-borrow path: unregistered → downloading is documented as allowed.
        // (See TokenRefreshInterceptor's handleProblem for the no-active-loan case.)
        XCTAssertTrue(TPPBookState.canTransition(from: .unregistered, to: .downloading))
    }

    func test_TPPBookState_disallowedTransitionsAreRejected() {
        // Negative property: clearly nonsensical transitions are not in the table.
        XCTAssertFalse(TPPBookState.canTransition(from: .downloadFailed, to: .downloadSuccessful),
                       "cannot succeed without a fresh download")
        XCTAssertFalse(TPPBookState.canTransition(from: .holding, to: .downloadSuccessful),
                       "must downloadNeeded → downloading first")
        XCTAssertFalse(TPPBookState.canTransition(from: .returning, to: .holding),
                       "returning is terminal toward unregistered")
    }
}
