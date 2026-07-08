//
//  CredentialSnapshotInvalidationTests.swift
//  PalaceTests
//
//  CP-D2 (swarm_27c181b5 Wave C). Locks the behavioural contract after
//  removing per-read keychain invalidation from
//  `TPPUserAccount.credentialSnapshot()`:
//
//    - credentialSnapshot() no longer drops the keychain cache on every
//      request build. It relies on the WRITE-THROUGH keychain cache
//      (`TPPKeychainVariable.write()` sets cachedValue AND persists) plus the
//      one-instance-per-library invariant (`AccountsManager.userAccount(for:)`
//      caches exactly one `TPPUserAccount` per UUID), so the instance that
//      writes credentials is the instance every reader reads.
//    - Coherence at the two out-of-band boundaries is preserved by
//      EVENT-DRIVEN invalidation instead: sign-out finalisation
//      (`removeAll()`) and account switch
//      (`AccountsManager.currentAccount.didSet`).
//
//  Isolation posture (integration finding, swarm_27c181b5 Wave C): every test
//  here drives an ISOLATED fresh `AccountsManager` (via `makeFreshAccountsManager`
//  + `makeTestAppContainer`) or bare peer `TPPUserAccount` instances — NEVER the
//  shared production singleton. An earlier revision drove the real
//  `AccountDetailViewModel` / `currentUserAccount` seam against
//  `AppContainer.production().accountsManager`; the view-model's init kicks off
//  an auth-document fetch that left an in-flight `.detailsLoading` transition on
//  the shared manager, which poisoned the single-flight `.detailsLoading` count
//  in `AccountsManagerStateMachineWiringTests` when these classes ran first.
//  Isolating onto a fresh manager (mirroring the account-switch test's
//  discipline) keeps the SAME real seams (real AccountDetailViewModel, real
//  credentialSnapshot, real currentUserAccount) while making cross-class bleed
//  structurally impossible. The tearDown also defensively drains + resets shared
//  state as belt-and-suspenders.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

final class CredentialSnapshotInvalidationTests: PalaceWiringTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every test round-trips credentials through TPPKeychain — skip on CI
        // hosts that return -34018 (missing entitlement), same gate as
        // TPPKeychainTests + TPPKeychainSwiftTests.
        try KeychainAvailability.skipIfUnavailable()
    }

    override func tearDownWithError() throws {
        // Defense-in-depth against cross-class pollution. Even though every test
        // here uses an isolated fresh AccountsManager, drain any in-flight
        // background/auth-doc fetch on the production singleton and wipe global
        // AccountStateStore transitions so a stray `.detailsLoading` cannot bleed
        // into a later class (this is what poisoned
        // AccountsManagerStateMachineWiringTests' single-flight count). The fresh
        // managers themselves are cancelled by the base class via
        // makeFreshAccountsManager tracking.
        AppContainer.production().accountsManager.cancelAndDrainBackgroundWork()
        AccountStateStore.shared._resetAllForTesting()
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Build an isolated fresh AccountsManager (its own UserDefaults suite),
    /// seed a unique fixture account as current, pre-set a terminal state so any
    /// state-machine drive early-returns (no network), and wrap it in a fresh
    /// AppContainer. Returns a cleanup closure the caller MUST defer-invoke.
    private func makeSeededIsolatedContainer(
        fixtureId: String
    ) -> (container: AppContainer, manager: AccountsManager, fixture: Account, cleanup: () -> Void) {
        let defaults = testUserDefaults()
        let manager = makeFreshAccountsManager(defaults: defaults)
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog", rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: fixtureId, title: "CP-D2 Fixture"),
            images: nil
        )
        let fixture = Account(publication: pub, imageCache: MockImageCache())
        let cleanupSeed = manager._seedAccountForTesting(fixture)
        // Terminal state ⇒ any driveCurrentAccountAuthDocIfNeeded early-returns.
        AccountStateStore.shared.setState(.detailsFailed(.accountNotFound(uuid: fixture.uuid)), for: fixture.uuid)
        let container = makeTestAppContainer(accountsManager: manager)
        let cleanup: () -> Void = {
            manager.userAccount(for: fixture.uuid).removeAll()
            AccountStateStore.shared.setState(.notLoaded, for: fixture.uuid)
            cleanupSeed()
        }
        return (container, manager, fixture, cleanup)
    }

    // MARK: - 1. Sign-out staleness through the real AccountDetailViewModel surface

    /// Phase 1a amendment #1: sign-out staleness must be proven through the REAL
    /// build-459 surface — `AccountDetailViewModel` — not two bare TPPUserAccount
    /// instances. A signed-in snapshot must go stale→fresh across sign-out and
    /// must NEVER read "signed in" after sign-out completes. Per-read
    /// invalidation used to paper over this; the write-through cache +
    /// removeAll() event-driven invalidation now carry it. Driven on an isolated
    /// fresh manager so the VM's init-time auth-doc fetch cannot bleed onto the
    /// production singleton.
    @MainActor
    func testSignOut_ThroughAccountDetailViewModel_GoesSignedInToSignedOut_neverStaleSignedIn() throws {
        let (container, manager, fixture, cleanup) = makeSeededIsolatedContainer(
            fixtureId: "cp-d2-signout-\(UUID().uuidString)"
        )
        defer { cleanup() }

        let account = manager.userAccount(for: fixture.uuid)
        account.removeAll()
        account.setBarcode("signed-in-user", PIN: "1234")
        account.setAuthState(.loggedIn)

        let viewModel = AccountDetailViewModel(libraryAccountID: fixture.uuid, appContainer: container)
        viewModel.refreshSignInState()
        XCTAssertTrue(viewModel.isSignedIn,
                      "Precondition: the view model must reflect the signed-in credentials")

        // Sign out through the production seam (write-through nils + the
        // event-driven invalidateAllKeychainCaches() inside removeAll()).
        account.removeAll()
        viewModel.refreshSignInState()

        XCTAssertFalse(viewModel.isSignedIn,
                       "After sign-out the view model must read signed-out — a stale 'signed in' here is the build-459 regression per-read invalidation used to hide")

        let post = manager.userAccount(for: fixture.uuid).credentialSnapshot()
        XCTAssertFalse(post.hasCredentials,
                       "Post-sign-out snapshot must expose no credentials")
        XCTAssertEqual(post.authState, .loggedOut,
                       "Post-sign-out snapshot must resolve to .loggedOut")
    }

    // MARK: - 4. The 401-decision read seam (currentUserAccount) is never stale

    /// The 401 / credentials-stale decision path reads
    /// `accountsManager.currentUserAccount.credentialSnapshot()`
    /// (`TPPNetworkResponder` lines 391 / 460 — OFF-LIMITS to edit). This
    /// exercises that exact read seam (on an isolated manager — the write-through
    /// coherence property under test is manager-agnostic) to prove CP-D2 did not
    /// weaken it: after sign-in the seam reads signed-in (a stale "signed out"
    /// would trigger a spurious logout), and after sign-out the seam reads
    /// signed-out (a stale "signed in" would suppress legitimate re-auth).
    /// Because the write path and this read path share one cached instance via
    /// the write-through cache — and removeAll() invalidates synchronously before
    /// it returns — the seam can never observe a snapshot older than the last
    /// completed sign-in/out.
    func testCurrentUserAccountSnapshot_reflectsSignInThenSignOut_soReauthDecisionInputIsNeverStale() throws {
        let (_, manager, fixture, cleanup) = makeSeededIsolatedContainer(
            fixtureId: "cp-d2-decision-\(UUID().uuidString)"
        )
        defer { cleanup() }

        XCTAssertEqual(manager.currentAccountId, fixture.uuid,
                       "Precondition: fixture is the current account (drives currentUserAccount)")

        // Sign in on the current account's cached instance.
        let account = manager.currentUserAccount
        account.removeAll()
        account.setBarcode("decision-user", PIN: "4242")
        account.setAuthState(.loggedIn)

        // The decision seam must read signed-in — a stale "signed out" here would
        // fire a spurious logout on the next 401.
        let afterSignIn = manager.currentUserAccount.credentialSnapshot()
        XCTAssertTrue(afterSignIn.hasCredentials,
                      "Decision seam must observe credentials immediately after sign-in — a stale 'signed out' would trigger a spurious logout")
        XCTAssertNotEqual(afterSignIn.authState, .loggedOut,
                          "authState must not read .loggedOut while signed in")

        // Sign out; removeAll() invalidates synchronously before returning.
        account.removeAll()

        // The decision seam must now read signed-out — a stale "signed in" here
        // would suppress legitimate re-authentication.
        let afterSignOut = manager.currentUserAccount.credentialSnapshot()
        XCTAssertFalse(afterSignOut.hasCredentials,
                       "Decision seam must observe the sign-out — a stale 'signed in' would suppress legitimate re-auth")
        XCTAssertEqual(afterSignOut.authState, .loggedOut,
                       "authState must read .loggedOut after sign-out")
    }

    // MARK: - 3. Cache-hit: repeated snapshots do NOT re-read the keychain

    /// CP-D2 core contract. Within a window with NO invalidation event, repeated
    /// `credentialSnapshot()` builds must hit the in-memory cache and must NOT
    /// re-read the keychain. We spy the read count BEHAVIOURALLY, which is exact
    /// here: two peer `TPPUserAccount` instances bound to the SAME library UUID
    /// share keychain keys but have independent in-memory caches. A peer writes
    /// credentials AFTER the reader has primed its cache. A keychain re-read (the
    /// removed per-read invalidation) would necessarily surface the peer write;
    /// its ABSENCE proves the read was served from cache. A subsequent explicit
    /// invalidation event then makes the write visible, proving the event-driven
    /// path restores coherence.
    func testCredentialSnapshot_withinNoInvalidationEvent_hitsCacheAndDoesNotRereadKeychain() throws {
        let libraryUUID = "cp-d2-cachehit-\(UUID().uuidString)"
        let reader = TPPUserAccount(libraryUUID: libraryUUID)
        let writer = TPPUserAccount(libraryUUID: libraryUUID)
        writer.removeAll()
        defer { writer.removeAll() }

        // Prime the reader's cache: no credentials yet.
        let primed = reader.credentialSnapshot()
        XCTAssertFalse(primed.hasCredentials,
                       "Precondition: reader starts with no credentials")

        // Peer write under the same keys — the reader's cache is now stale
        // relative to the keychain.
        writer.setBarcode("peer-write", PIN: "1")

        // CACHE HIT: the reader must STILL report no credentials because it did
        // NOT re-read the keychain. If per-read invalidation were restored this
        // would flip to hasCredentials == true and the assertion fails.
        let cached = reader.credentialSnapshot()
        XCTAssertFalse(cached.hasCredentials,
                       "credentialSnapshot() must hit the cache — a peer write must NOT surface without an invalidation event; visibility here means the keychain was re-read on every build (the removed behaviour)")

        // EVENT-DRIVEN invalidation restores coherence: the reader re-reads.
        reader.invalidateCredentialCaches()
        let fresh = reader.credentialSnapshot()
        XCTAssertTrue(fresh.hasCredentials,
                      "After invalidateCredentialCaches() the reader must re-read the keychain and observe the peer write")
        XCTAssertEqual(fresh.barcode, "peer-write",
                       "The re-read snapshot must carry the peer-written barcode")
    }

    /// Complementary direction: the invalidation event must also expose a peer
    /// REMOVE (sign-out mirror). Prime with credentials, peer-clears them, and
    /// the stale cache must keep reporting signed-in until the event fires.
    func testCredentialSnapshot_peerRemoveAll_isHiddenUntilInvalidationEvent() throws {
        let libraryUUID = "cp-d2-cachehit-remove-\(UUID().uuidString)"
        let reader = TPPUserAccount(libraryUUID: libraryUUID)
        let writer = TPPUserAccount(libraryUUID: libraryUUID)
        writer.removeAll()
        defer { writer.removeAll() }

        writer.setBarcode("existing", PIN: "0000")
        let primed = reader.credentialSnapshot()
        XCTAssertTrue(primed.hasCredentials,
                      "Precondition: reader primes with the peer-written credentials")

        // Peer clears credentials — reader cache still holds the old value.
        writer.removeAll()

        let cached = reader.credentialSnapshot()
        XCTAssertTrue(cached.hasCredentials,
                      "Without an invalidation event the reader must keep serving the cached signed-in value (proves no per-read re-read)")

        reader.invalidateCredentialCaches()
        let fresh = reader.credentialSnapshot()
        XCTAssertFalse(fresh.hasCredentials,
                       "After the invalidation event the reader must re-read and observe the peer removeAll")
        XCTAssertEqual(fresh.authState, .loggedOut,
                       "Re-read snapshot after peer removeAll must resolve to .loggedOut")
    }

    // MARK: - 2. Account-switch invalidation through the real currentAccount setter

    /// Phase 1a amendment #2: switching the current library must invalidate the
    /// newly-current account's credential cache through the REAL
    /// `AccountsManager.currentAccount` setter — not a shortcut. We prime the new
    /// account's cached instance as signed-out, then write credentials out of
    /// band (a peer instance under the same keys), then drive the switch. The
    /// `currentAccount.didSet` invalidation must force the next snapshot to
    /// re-read the keychain and observe the out-of-band write. Removing the
    /// invalidation call leaves the primed (stale) cache in place and this test
    /// fails.
    func testAccountSwitch_invalidatesNewlyCurrentAccountCredentialCache() throws {
        let defaults = testUserDefaults()
        let mgr = makeFreshAccountsManager(defaults: defaults)

        // Seed a fixture account and make it resolvable via account(uuid), then
        // clear the persisted current-account key so the switch below is a real
        // nil→B transition (skips the heavy A→B cleanup branch).
        let switchUUID = "cp-d2-switch-\(UUID().uuidString)"
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog", rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: switchUUID, title: "CP-D2 Switch Fixture"),
            images: nil
        )
        let fixture = Account(publication: pub, imageCache: MockImageCache())
        let cleanupSeed = mgr._seedAccountForTesting(fixture)
        defer { cleanupSeed() }
        defaults.removeObject(forKey: currentAccountIdentifierKey)
        XCTAssertNil(mgr.currentAccountId,
                     "Precondition: current account must be nil so the switch is a real nil→B transition")

        // Pre-set the fixture's state to a terminal that makes the setter's
        // driveCurrentAccountAuthDocIfNeeded() early-return (no network fetch):
        // the `.detailsFailed` arm returns without driving.
        AccountStateStore.shared.setState(.detailsFailed(.accountNotFound(uuid: fixture.uuid)), for: fixture.uuid)
        defer { AccountStateStore.shared.setState(.notLoaded, for: fixture.uuid) }

        // Prime the manager's cached instance for the new account: signed-out.
        let managed = mgr.userAccount(for: fixture.uuid)
        managed.removeAll()
        let primed = managed.credentialSnapshot()
        XCTAssertFalse(primed.hasCredentials,
                       "Precondition: the newly-current account instance primes as signed-out")

        // Out-of-band write via a peer instance under the same library keys — the
        // managed instance's cache is now stale.
        let peer = TPPUserAccount(libraryUUID: fixture.uuid)
        peer.setBarcode("switched-in", PIN: "1")
        peer.setAuthState(.loggedIn)
        defer { peer.removeAll() }

        // Drive the REAL account-switch seam.
        mgr.currentAccount = fixture

        // The switch must have invalidated the managed instance's cache, so its
        // next snapshot re-reads the keychain and observes the out-of-band write.
        let afterSwitch = mgr.userAccount(for: fixture.uuid).credentialSnapshot()
        XCTAssertTrue(afterSwitch.hasCredentials,
                      "Account switch must invalidate the newly-current account's cache so its snapshot re-reads fresh keychain state")
        XCTAssertEqual(afterSwitch.barcode, "switched-in",
                       "Post-switch snapshot must carry the out-of-band barcode")

        mgr.userAccount(for: fixture.uuid).removeAll()
    }
}
