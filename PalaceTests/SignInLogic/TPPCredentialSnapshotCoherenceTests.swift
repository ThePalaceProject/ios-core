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
//  invalidates on a key change. The sign-in/out pipeline writes via the
//  singleton instance, so the per-account instance's caches go stale and
//  `credentialSnapshot()` returns "signed in" state after sign-out has
//  persisted to the keychain.
//
//  Fix: `credentialSnapshot()` now toggles `libraryUUID` (nil → uuid)
//  before reading, mirroring the static class-level method. The key re-bind
//  invalidates every variable's `alreadyInited` cache flag, forcing a
//  fresh keychain read.
//
//  These tests pin the fix by writing through one instance and reading
//  through another — any regression that re-introduces the cache coherence
//  bug will fail here.
//

import XCTest
@testable import Palace

final class TPPCredentialSnapshotCoherenceTests: XCTestCase {

    private let testLibraryUUID = "test-coherence-\(UUID().uuidString)"
    private var writer: TPPUserAccount!
    private var reader: TPPUserAccount!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // CI iOS Simulator runners have no keychain entitlement, so every
        // setBarcode/setAuthToken silently no-ops and these cache-coherence
        // assertions all fail with `nil != "test-barcode"`. Skip rather
        // than report false negatives — the regression these tests guard
        // against can only happen on a host with a real keychain.
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

        // Reader must see the new credentials. Without the force-refresh
        // inside credentialSnapshot(), this fails because the reader's
        // TPPKeychainVariable caches still report the pre-write nil state.
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
        // write we're verifying.
        _ = reader.credentialSnapshot()

        writer.removeAll()

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
        _ = reader.credentialSnapshot() // prime cache

        writer.markCredentialsStale()

        let after = reader.credentialSnapshot()
        XCTAssertEqual(after.authState, .credentialsStale,
                       "Peer-instance markCredentialsStale must be visible — " +
                       "401-triggered re-auth flow depends on this")
    }
}
