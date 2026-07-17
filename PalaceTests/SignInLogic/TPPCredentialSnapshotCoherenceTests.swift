//
//  TPPCredentialSnapshotCoherenceTests.swift
//  PalaceTests
//
//  Regression guard for the build-459 → HEAD UI refresh bug.
//
//  Context: after PR #822 introduced per-account `TPPUserAccount` instances
//  and AccountDetailViewModel switched from the static class-level
//  `TPPUserAccount.credentialSnapshot(for:)` to the per-instance method,
//  the sign-in/sign-out UI stopped updating. Root cause: each
//  `TPPKeychainVariable` caches its last-read value in memory and only
//  invalidates explicitly. Historically two instances could point at the same
//  library (a singleton writer + a per-account reader), so the reader's cache
//  went stale after the writer persisted a change.
//
//  Contract as of CP-D2 (swarm_27c181b5 Wave C): production keeps exactly ONE
//  `TPPUserAccount` per library UUID (`AccountsManager.userAccount(for:)`
//  cache) and the keychain cache is write-through, so the single production
//  instance is always self-coherent WITHOUT re-reading the keychain on every
//  `credentialSnapshot()`. Cross-instance / out-of-band coherence is now
//  carried by EVENT-DRIVEN invalidation (`invalidateCredentialCaches()`, fired
//  on sign-out finalisation and account switch) rather than per-read
//  invalidation.
//
//  These tests still write through one instance and read through a peer, but
//  they now fire the invalidation EVENT (the production seam) between the peer
//  write and the coherence read — proving the event-driven mechanism keeps
//  peers coherent. A regression that drops the event-driven invalidation, or
//  that breaks the write-through cache, fails here.
//

import XCTest
import PalaceKeychain
@testable import Palace

@MainActor
final class TPPCredentialSnapshotCoherenceTests: XCTestCase {

    private let testLibraryUUID = "test-coherence-\(UUID().uuidString)"
    private var writer: TPPUserAccount!
    private var reader: TPPUserAccount!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Whole suite exercises keychain round-tripping between peer
        // TPPUserAccount instances. Skip in CI where SecItem calls return
        // -34018 (missing entitlement) — same env-gate as
        // TPPKeychainTests + TPPKeychainSwiftTests.
        try KeychainAvailability.skipIfUnavailable()
        writer = TPPUserAccount(libraryUUID: testLibraryUUID)
        reader = TPPUserAccount(libraryUUID: testLibraryUUID)
        writer.removeAll()
    }

    override func tearDown() {
        writer?.removeAll()
        writer = nil
        reader = nil
        super.tearDown()
    }

    // Core regression: a write via one instance must be visible on another
    // instance pointing at the same library. This is exactly the sign-out
    // flow (singleton writes, per-account reads).
    func testCredentialSnapshot_ReflectsWriteFromPeerInstance() {
        // Prime the reader's cache so `alreadyInited` gets set on the
        // underlying TPPKeychainVariable objects.
        let before = reader.credentialSnapshot()
        XCTAssertFalse(before.hasCredentials,
                       "precondition: no credentials after setUp removeAll")

        // Write via the peer instance (mirrors the singleton sign-in path).
        writer.setBarcode("test-barcode", PIN: "1234")

        // Fire the event-driven invalidation on the reader (the production
        // seam a sign-in/switch triggers). credentialSnapshot() no longer
        // re-reads the keychain per call, so without this event the reader's
        // caches would still report the pre-write nil state.
        reader.invalidateCredentialCaches()

        // Reader must now see the new credentials.
        let after = reader.credentialSnapshot()
        XCTAssertTrue(after.hasCredentials,
                      "Peer-instance write must be visible in this instance's snapshot — " +
                      "if false, the keychain-variable cache-coherence fix has regressed")
        XCTAssertEqual(after.barcode, "test-barcode")
    }

    // Sign-out mirror: primed cache shows hasCredentials=true, peer writes
    // nil, snapshot must see the clear.
    func testCredentialSnapshot_ReflectsRemoveAllFromPeerInstance() {
        writer.setBarcode("existing", PIN: "0000")
        // Prime the reader's cache so removeAll() through the peer is the
        // write we're verifying. The reader needs a fresh read first to see
        // the writer's initial credentials (event-driven, not per-read).
        reader.invalidateCredentialCaches()
        _ = reader.credentialSnapshot()

        writer.removeAll()

        // Fire the invalidation event (production sign-out seam) so the reader
        // re-reads the cleared keychain.
        reader.invalidateCredentialCaches()

        let after = reader.credentialSnapshot()
        XCTAssertFalse(after.hasCredentials,
                       "Peer-instance removeAll must be visible as hasCredentials=false — " +
                       "if true, sign-out UI will stay stuck showing signed-in state")
        XCTAssertEqual(after.authState, .loggedOut,
                       "Snapshot must resolve to .loggedOut after peer removeAll")
    }

    // authState transition coherence — the publisher's hasCredentials
    // subscription relies on this path.
    func testCredentialSnapshot_AuthStateTransitions_ArePeerVisible() {
        writer.setBarcode("abc", PIN: "1234")
        writer.markLoggedIn()
        reader.invalidateCredentialCaches()
        _ = reader.credentialSnapshot() // prime cache with logged-in state

        writer.markCredentialsStale()

        // Fire the invalidation event so the reader observes the stale-state
        // transition the writer just persisted.
        reader.invalidateCredentialCaches()

        let after = reader.credentialSnapshot()
        XCTAssertEqual(after.authState, .credentialsStale,
                       "Peer-instance markCredentialsStale must be visible — " +
                       "401-triggered re-auth flow depends on this")
    }
}
