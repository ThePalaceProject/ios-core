//
//  TPPSignInBusinessLogicStateMachineTests.swift
//  PalaceTests
//
//  Bucket A migration tests for TPPSignInBusinessLogic (swarm_81b5099e
//  Phase 1). Pins the six sub-sites in TPPSignInBusinessLogic.swift that
//  used to read `libraryAccount?.details?.<field>` against the
//  `Account.LoadState` state machine.
//
//  Each test drives the AccountStateStore directly via `account._setState`
//  to simulate the three load-readiness windows that previously raced:
//    1. `.detailsLoading` — the legacy path silently returned nil; the
//       migration must also return nil/false (sync sites cannot block).
//    2. `.detailsLoaded(details)` — both legacy and migrated paths
//       proceed; assert the post-load behavior matches.
//    3. `.detailsFailed(error)` — legacy returned nil (because
//       `account.details` was never assigned); migrated path must NOT
//       crash and must surface the same nil-semantic.
//
//  Per ADR `docs/architecture/account-state-machine.md`, the 6 sub-sites
//  in TPPSignInBusinessLogic.swift are sync `@objc` / property getters
//  read from SwiftUI render bodies; they peek `loadState` synchronously
//  rather than `await awaitReady()` to avoid cascading `async` upward
//  through the entire sign-in UI. The state-machine-aware sync read
//  preserves the legacy nil-tolerance while routing through the new API.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPSignInBusinessLogicStateMachineTests: XCTestCase {

    private var businessLogic: TPPSignInBusinessLogic!
    private var libraryAccountMock: TPPLibraryAccountMock!
    private var drmAuthorizer: TPPDRMAuthorizingMock!
    private var uiDelegate: TPPSignInOutBusinessLogicUIDelegateMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TPPUserAccountMock.resetShared()
        libraryAccountMock = TPPLibraryAccountMock()
        drmAuthorizer = TPPDRMAuthorizingMock()
        uiDelegate = TPPSignInOutBusinessLogicUIDelegateMock()
        businessLogic = TPPSignInBusinessLogic(
            libraryAccountID: libraryAccountMock.tppAccountUUID,
            libraryAccountsProvider: libraryAccountMock,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: TPPBookRegistryMock(),
            bookDownloadsCenter: TPPMyBooksDownloadsCenterMock(),
            userAccountProvider: TPPUserAccountMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: uiDelegate,
            drmAuthorizer: drmAuthorizer
        )
    }

    override func tearDownWithError() throws {
        (businessLogic.networker as? TPPRequestExecutorMock)?.reset()
        businessLogic.userAccount.removeAll()
        businessLogic = nil
        libraryAccountMock = nil
        drmAuthorizer = nil
        uiDelegate = nil
        // The state machine lives in AccountStateStore.shared keyed by UUID;
        // reset it so one test's `.detailsFailed` doesn't leak into the
        // next test's initial-state assertions.
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// The Account behind `libraryAccount` in our mock provider.
    private var libraryAccount: Account {
        libraryAccountMock.tppAccount
    }

    /// AccountDetails loaded from the canned auth-document fixture. Used
    /// to drive `.detailsLoaded(_:)` in tests that need a real details
    /// object with `signUpUrl`, `auths`, `userProfileUrl`, EULA, etc.
    private var realDetails: AccountDetails {
        // The fixture has populated details once the mock's
        // `authenticationDocument` was assigned during init.
        libraryAccount.details!
    }

    /// Convenience: drive the state machine for the library account this
    /// businessLogic is signing in against.
    private func setLoadState(_ state: Account.LoadState) {
        libraryAccount._setState(state)
    }

    // MARK: - testSignIn_blocksUntilLoaded_thenProceeds
    //
    // Contract: while details are still loading (`.detailsLoading`), the
    // sync sign-in surface returns nil/false — same null-semantic as the
    // legacy `libraryAccount?.details?.userProfileUrl` read. Once the
    // state transitions to `.detailsLoaded`, the sign-in request can be
    // built. This is the F-016 → sign-in repro: the sign-in path used to
    // silently take the "no URL" branch when racing the auth doc fetch;
    // with the state machine, that branch is now state-driven instead of
    // a silent nil race.

    func testSignIn_blocksUntilLoaded_thenProceeds() {
        // Pre-state: details still loading. The legacy path read
        // `libraryAccount?.details?.userProfileUrl` and silently returned
        // nil; the migration peeks `.loadState`, sees `.detailsLoading`,
        // and likewise returns nil.
        setLoadState(.detailsLoading)
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let preReq = businessLogic.makeRequest(for: .signIn, context: "pre-load")
        XCTAssertNil(preReq, "sign-in request must be nil while details are still loading — matches the legacy nil-semantic that silently raced")

        // Transition: details land. The sign-in request now builds.
        setLoadState(.detailsLoaded(realDetails))

        let postReq = businessLogic.makeRequest(for: .signIn, context: "post-load")
        XCTAssertNotNil(postReq, "sign-in request must build once details are loaded — userProfileUrl is now state-machine-readable")
    }

    // MARK: - testSignIn_failedDetailsLoad_surfacesError
    //
    // Contract: when the auth-doc fetch fails (`.detailsFailed`), the
    // sign-in surface returns nil (no URL → caller takes its existing
    // error branch). The migration must NOT crash on `.detailsFailed`;
    // it must read state, not raw `details?`, and surface the nil result
    // its callers already handle.

    func testSignIn_failedDetailsLoad_surfacesError() {
        setLoadState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "HTTP 503")))
        businessLogic.selectedAuthentication = libraryAccountMock.barcodeAuthentication

        let req = businessLogic.makeRequest(for: .signIn, context: "after fetch failure")
        XCTAssertNil(req, "sign-in request must be nil after auth-doc fetch failure — caller surfaces the noURL error to the user")

        // `registrationIsPossible` reads `signUpUrl`; on .detailsFailed
        // there is no URL, so registration is not possible.
        XCTAssertFalse(businessLogic.registrationIsPossible(),
                       "registrationIsPossible must be false on .detailsFailed — no signUpUrl to launch")

        // `shouldShowEULALink` reads `getLicenseURL(.eula)`; on
        // .detailsFailed there is no EULA URL to link to.
        XCTAssertFalse(businessLogic.shouldShowEULALink(),
                       "shouldShowEULALink must be false on .detailsFailed — no EULA URL to link to")
    }

    // MARK: - testIsSamlAuth_failedDetailsLoad_returnsFalse
    //
    // Contract: line 736 specifically. The legacy code was
    // `libraryAccount?.details?.auths.contains { $0.isSaml } ?? false`;
    // the migration reads `loadedAccountDetails?.auths...`. Both return
    // `false` on `.detailsFailed`. This test exists to PIN that the
    // migration does NOT crash on `.detailsFailed` (would happen if a
    // future refactor switched to force-unwrap or `try!`-await).

    func testIsSamlAuth_failedDetailsLoad_returnsFalse() {
        // Pair-assert that .detailsLoading also returns false — so a mutation
        // that crashes/returns true on .detailsFailed (but not loading) is
        // caught. Pins the contract that NEITHER pre-loaded state surfaces
        // a SAML "yes" answer.
        setLoadState(.detailsFailed(.malformedAuthDocument(reason: "missing auths array")))
        let failedResult = businessLogic.isSamlPossible()
        setLoadState(.detailsLoading)
        let loadingResult = businessLogic.isSamlPossible()

        XCTAssertFalse(failedResult,
                       "isSamlPossible must return false on .detailsFailed — matches the legacy nil-semantic, does NOT crash")
        XCTAssertFalse(loadingResult,
                       "isSamlPossible must also return false on .detailsLoading — pre-load states do not advertise SAML")
    }

    // MARK: - Coverage of the other migrated sub-sites
    //
    // The contract names three required tests (above), but the migration
    // touches six sub-sites. Pin the remaining three to the same state
    // machine semantics so a future refactor that accidentally bypasses
    // `loadedAccountDetails` regresses one of these tests.

    func testIsSamlPossible_loaded_returnsTrueWhenSamlAuthPresent() {
        // Pair-assert that going BACK to .detailsLoading flips the predicate
        // to false — pinning the contract is state-driven, not latched. A
        // mutation that latches true after the first .detailsLoaded would be
        // caught here.
        setLoadState(.detailsLoaded(realDetails))
        XCTAssertTrue(businessLogic.isSamlPossible(),
                      "isSamlPossible must reflect the loaded auths array — fixture contains a SAML auth")
        setLoadState(.detailsLoading)
        XCTAssertFalse(businessLogic.isSamlPossible(),
                       "Reverting to .detailsLoading must flip isSamlPossible back to false — predicate is state-driven, not latched")
    }

    func testRegistrationIsPossible_loaded_returnsTrueWhenSignUpUrlPresent() {
        // Caller is not signed in; details are loaded; the fixture has a
        // signUpUrl. registrationIsPossible() must be true.
        setLoadState(.detailsLoaded(realDetails))
        XCTAssertTrue(businessLogic.registrationIsPossible(),
                      "registrationIsPossible must be true when not signed in AND signUpUrl is reachable via the state machine")

        // Compare to .detailsLoading: same not-signed-in state, but no
        // URL yet. Must be false.
        setLoadState(.detailsLoading)
        XCTAssertFalse(businessLogic.registrationIsPossible(),
                       "registrationIsPossible must be false while details are still loading")
    }

    func testSelectPreferredAuthIfNeeded_loaded_picksSamlOverDefault() {
        // The fixture has multiple auths (basic + oauth + saml + oidc).
        // selectPreferredAuthIfNeeded should auto-select SAML when
        // selectedAuthentication is nil. State-machine path must give the
        // same result as the legacy details-read path.
        setLoadState(.detailsLoaded(realDetails))
        XCTAssertNil(businessLogic.selectedAuthentication,
                     "pre-condition: selectedAuthentication starts nil")

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertTrue(businessLogic.selectedAuthentication?.isSaml ?? false,
                      "selectPreferredAuthIfNeeded must auto-select SAML when multiple auths are advertised")
    }

    func testSelectPreferredAuthIfNeeded_loading_doesNotMutate() {
        // While details are loading, the method must be a no-op — there
        // are no auths to choose from. This pins the legacy behavior:
        // `libraryAccount?.details?.auths` returning nil meant the
        // method's body short-circuited.
        setLoadState(.detailsLoading)
        XCTAssertNil(businessLogic.selectedAuthentication)

        businessLogic.selectPreferredAuthIfNeeded()

        XCTAssertNil(businessLogic.selectedAuthentication,
                     "selectPreferredAuthIfNeeded must not mutate selectedAuthentication while details are still loading")
    }

    func testShouldShowEULALink_loaded_reflectsEulaUrlAndSignInState() {
        // EULA link visibility = (loaded details has EULA URL) AND (not
        // signed in). Fixture has the EULA URL; user is not signed in;
        // expect true. Pair-assert .detailsLoading returns false — pinning
        // that the EULA visibility predicate is state-aware, not a constant.
        setLoadState(.detailsLoaded(realDetails))
        XCTAssertTrue(businessLogic.shouldShowEULALink(),
                      "shouldShowEULALink must be true on .detailsLoaded with EULA URL + not signed in")
        setLoadState(.detailsLoading)
        XCTAssertFalse(businessLogic.shouldShowEULALink(),
                       ".detailsLoading must hide the EULA link — no URL available yet, predicate is state-driven")
    }

    func testSelectedAuthentication_loading_returnsNil() {
        // The getter path at line 281: while details are loading, the
        // getter must return nil (caller chooses an auth via the UI). On
        // .detailsLoading the legacy path read `details?.auths` → nil →
        // returned nil; the migration peeks `.loadState` → same nil
        // result, same UI behavior. Pair-assert that the result is also nil
        // on .detailsFailed — pinning the full not-loaded family, not just
        // the loading half.
        setLoadState(.detailsLoading)
        let loadingResult = businessLogic.selectedAuthentication
        setLoadState(.detailsFailed(.malformedAuthDocument(reason: "test")))
        let failedResult = businessLogic.selectedAuthentication

        XCTAssertNil(loadingResult,
                     "selectedAuthentication must be nil while details are still loading")
        XCTAssertNil(failedResult,
                     "selectedAuthentication must also be nil on .detailsFailed — the whole pre-loaded family returns nil")
    }
}
