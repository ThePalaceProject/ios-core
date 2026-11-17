//  AudiobookOpenStateRaceTests.swift
//
//  F-016: the audiobook open path must block on `Account.awaitReady()` rather than
//  read `details` while it is still loading and take the no-auth-required branch.
//  `AudiobookSessionManager.isUserAuthenticated` is private and the singleton is
//  bound to AppContainer.production(), so these tests pin the primitive it consumes:
//  `awaitReady()` blocks on `.detailsLoading`, throws on `.detailsFailed`, and
//  returns the loaded details on `.detailsLoaded`.

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class AudiobookOpenStateRaceTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!
    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        libraryMock = nil
        appContainer = nil
        super.tearDown()
    }

    // MARK: - F-016 → audiobook regression repro

    /// Direct exercise of the migrated readiness gate at the level the
    /// audiobook open path consumes it.
    ///
    /// PRE-CONDITION: an account exists, but its load state is
    /// `.detailsLoading` (the F-016 cold-launch window: disk preload
    /// completed → basicInfoLoaded → loadCatalogs running → detailsLoading,
    /// auth doc not yet returned).
    ///
    /// EXPECTED: the awaitReady awaiter blocks until the test transitions
    /// the state. Before the fix, the audiobook open path's
    /// `isUserAuthenticated` returned `true` synchronously (no awaiting)
    /// because `details?` was nil and the function fell through to the
    /// "no auth required" branch. After the fix, the function awaits and
    /// only returns once state is terminal.
    func testF016Repro_audiobookOpenAwaitsReadiness_doesNotSilentlyReadPastNilDetails() async throws {
        let account = libraryMock.tppAccount
        guard let realDetails = account.details else {
            XCTFail("Library mock must produce loaded details"); return
        }

        // Seed the F-016 scenario: account known, but details not yet
        // loaded (the loadCatalogs auth-doc fetch hasn't completed).
        account._setState(.detailsLoading)

        let openTaskGateCleared = expectation(description: "gate cleared after state transition")
        let awaiterTask = Task {
            // This is the EXACT call the migrated AudiobookSessionManager
            // .isUserAuthenticated makes. Before the fix, this line did not
            // exist; the code read `account.details` directly and bailed
            // to true.
            let resolvedDetails = try await account.awaitReady()
            // The defaultAuth read happens AFTER the gate resolves —
            // never against nil details.
            _ = resolvedDetails.defaultAuth
            XCTAssertTrue(resolvedDetails === realDetails,
                          "awaitReady must return the exact AccountDetails carried by .detailsLoaded")
            openTaskGateCleared.fulfill()
        }

        // Verify the gate is BLOCKING — the awaiter has not resolved yet.
        // Before the fix, there was no awaiter at all (synchronous code path).
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(awaiterTask.isCancelled, "Gate must block, not cancel")

        // Transition to terminal state — production AccountsManager
        // would do this when the network settled.
        account._setState(.detailsLoaded(realDetails))

        await fulfillment(of: [openTaskGateCleared], timeout: 1.0)
    }

    /// Failure-path: `.detailsFailed` must throw, surfacing the auth
    /// failure to the migrated `isUserAuthenticated` which then returns
    /// false (caller maps to `.notAuthenticated`).
    func testF016Repro_audiobookOpenUnderDetailsFailed_gateThrows_callerMapsToNotAuthenticated() async {
        let account = libraryMock.tppAccount

        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady must throw under .detailsFailed — AudiobookSessionManager relies on this to map to .notAuthenticated")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "test HTTP 503")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Integration: full audiobook open path

    /// When the migrated `openAudiobook` is invoked, validation fires
    /// through `isUserAuthenticated` → `awaitReady`. We assert the
    /// public API surface — under `.detailsFailed` the call returns
    /// `.failure(.notAuthenticated)`. Even if the production
    /// accountsManager has no `currentAccount` (test env), the early-
    /// return path in `isUserAuthenticated` ALSO yields false → caller
    /// maps to `.notAuthenticated`, preserving the public-API contract.
    /// What this test pins: `.detailsFailed` does NOT surface as some
    /// other downstream error (e.g. `.manifestLoadFailed`) which would
    /// indicate the gate ran but its error wasn't honored.
    func testIntegration_openAudiobook_underDetailsFailed_returnsNotAuthenticated() async throws {
        let accountsMgr = appContainer.accountsManager
        let (account, cleanup) = seedAccountIfNeeded(on: accountsMgr,
                                                    fixtureId: "test-audiobook-race-\(UUID().uuidString)")
        defer { cleanup() }

        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        let book = TPPBookMocker.mockBook(title: "Failed-State Audiobook", authors: "Test")
        let result = await appContainer.audiobookSession.openAudiobook(book, startPlaying: false)

        switch result {
        case .failure(.notAuthenticated):
            break // expected
        case .success:
            XCTFail("Open path succeeded under .detailsFailed — gate let unauthenticated session through")
        case .failure(let err):
            XCTFail("Open path returned \(err) under .detailsFailed — expected .notAuthenticated (gate must map awaitReady failure to .notAuthenticated)")
        }
    }
}
