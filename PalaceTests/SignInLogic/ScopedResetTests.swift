//
//  ScopedResetTests.swift
//  PalaceTests
//
//  Locks the contract for `performScopedReset` — the active-library-ONLY reset
//  promoted to Developer Settings (2026-06-08). The whole point of this path
//  (vs the nuclear `performForceReset`) is that it must NOT touch any other
//  library:
//    - per-library book/registry/credential reset (scoped to libraryAccountID)
//    - NO Adobe DRM device deauthorize (device-wide → would break other libs)
//    - web cookies deleted host-precisely, so a sibling library sharing a base
//      domain (the *.palaceproject.io / #1018 collision) is NOT signed out
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class ScopedResetTests: XCTestCase {

    private let ephemeralKey = TPPSignInBusinessLogic.nextOIDCSessionEphemeralKey
    private var savedDefaults: UserDefaults!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        savedDefaults = TPPSignInBusinessLogic.forceResetUserDefaults
        defaults = testUserDefaults()
        TPPSignInBusinessLogic.forceResetUserDefaults = defaults
    }

    override func tearDown() {
        TPPSignInBusinessLogic.forceResetUserDefaults = savedDefaults
        defaults = nil
        savedDefaults = nil
        super.tearDown()
    }

    // MARK: - hostMatches: the per-library cookie-isolation correctness logic

    /// Exact host match.
    func testHostMatches_exactHost_matches() {
        XCTAssertTrue(
            TPPSignInBusinessLogic.hostMatches("minotaur.dev.palaceproject.io",
                                               ["minotaur.dev.palaceproject.io"]),
            "An exact host must match its own auth-surface host"
        )
    }

    /// Leading-dot cookie domain (`.host`) still matches the host.
    func testHostMatches_leadingDotCookieDomain_matches() {
        XCTAssertTrue(
            TPPSignInBusinessLogic.hostMatches(".minotaur.dev.palaceproject.io",
                                               ["minotaur.dev.palaceproject.io"]),
            "A leading-dot cookie domain must normalize and match the host"
        )
    }

    /// A parent-domain cookie that covers the host is cleared (the cookie
    /// applies to the host, so leaving it would leave the host logged in).
    func testHostMatches_parentDomainCookieCoveringHost_matches() {
        XCTAssertTrue(
            TPPSignInBusinessLogic.hostMatches("dev.palaceproject.io",
                                               ["minotaur.dev.palaceproject.io"]),
            "A parent-domain cookie that covers the target host must be cleared"
        )
    }

    /// THE crown-jewel assertion: a SIBLING library on the same base domain is
    /// NOT matched. minotaur (active) reset must not delete gorgon's cookie.
    /// This is the #1018 *.palaceproject.io collision — the exact reason the
    /// blanket WKWebsiteDataStore wipe over-cleared other libraries.
    func testHostMatches_siblingHostOnSharedBaseDomain_doesNotMatch() {
        XCTAssertFalse(
            TPPSignInBusinessLogic.hostMatches("gorgon.staging.palaceproject.io",
                                               ["minotaur.dev.palaceproject.io"]),
            "A sibling library's host on the SAME base domain must NOT match — resetting the active library must not sign the patron out of other libraries"
        )
    }

    /// Mutation guard for the dot-boundary in the parent-domain arm. The match
    /// is `host.hasSuffix("." + normalized)`. Dropping the leading "." would let
    /// a cookie domain that is a RAW suffix of the host ("aceproject.io" of
    /// "palaceproject.io") falsely match and over-clear — the precise
    /// `*.palaceproject.io` collision this primitive exists to prevent. The
    /// sibling test doesn't construct a raw-suffix collision, so without this
    /// the mutant survives. (SoD qa_test review rev_278f26d6.)
    func testHostMatches_rawSuffixWithoutDotBoundary_doesNotMatch() {
        XCTAssertFalse(
            TPPSignInBusinessLogic.hostMatches("aceproject.io", ["palaceproject.io"]),
            "A cookie domain that is a raw (non-dot-boundary) suffix of the target host must NOT match — dropping the dot-boundary re-introduces *.palaceproject.io over-clearing"
        )
    }

    /// An unrelated domain is never matched.
    func testHostMatches_unrelatedDomain_doesNotMatch() {
        XCTAssertFalse(
            TPPSignInBusinessLogic.hostMatches("login.example.com",
                                               ["minotaur.dev.palaceproject.io"]),
            "An unrelated cookie domain must not be cleared"
        )
    }

    /// Empty target set never matches anything (basic-auth library, no web surface).
    func testHostMatches_emptyHostSet_neverMatches() {
        XCTAssertFalse(
            TPPSignInBusinessLogic.hostMatches("anything.example.com", []),
            "With no auth-surface hosts there is nothing to clear"
        )
    }

    // MARK: - webHostsToClear

    /// Nil account (cold launch / not found) yields no hosts — the web step
    /// becomes a no-op rather than falling back to a blanket wipe.
    func testWebHostsToClear_nilAccount_isEmpty() {
        XCTAssertEqual(
            TPPSignInBusinessLogic.webHostsToClear(for: nil), [],
            "A nil account must produce an empty host set (no blanket wipe fallback)"
        )
    }

    // MARK: - performScopedReset behavioral contract

    /// The scoped reset clears THIS library's books/registry/credentials and
    /// sets the one-shot ephemeral flag — but does NOT deauthorize Adobe DRM
    /// (device-wide) and does NOT touch other libraries.
    func testPerformScopedReset_resetsActiveLibraryOnly_andSkipsDRMDeauthorize() {
        let provider = TPPLibraryAccountMock()
        let spyUserAccount = TPPUserAccountMock()
        // account("") → nil, so the FCM + WKWebsite system calls are skipped;
        // we assert the spy-observable per-library contract deterministically.
        provider.userAccountResolver = { (_: String) in spyUserAccount }

        let registry = TPPBookRegistryMock()
        let downloads = TPPMyBooksDownloadsCenterMock()
        let drm = TPPDRMAuthorizingMock()

        let sut = TPPSignInBusinessLogic(
            libraryAccountID: "",
            libraryAccountsProvider: provider,
            urlSettingsProvider: TPPURLSettingsProviderMock(),
            bookRegistry: registry,
            bookDownloadsCenter: downloads,
            userAccountProvider: TPPUserAccountProviderMock.self,
            networkExecutor: TPPRequestExecutorMock(),
            uiDelegate: nil,
            drmAuthorizer: drm
        )

        let done = expectation(description: "scoped reset completes")
        sut.performScopedReset { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(downloads.resetCalledLibraryIDs, [""],
                       "Downloads must be reset for the active library exactly once")
        XCTAssertEqual(registry.resetCalledLibraryIDs, [""],
                       "Registry must be reset for the active library exactly once")
        XCTAssertEqual(spyUserAccount.removeAllCallCount, 1,
                       "This library's credentials must be cleared exactly once")
        XCTAssertFalse(drm.deauthorizeWasCalled,
                       "Scoped reset must NOT deauthorize Adobe DRM — that is device-wide and would break OTHER libraries. Only Full Reset deauthorizes.")
        XCTAssertTrue(defaults.bool(forKey: ephemeralKey),
                      "Scoped reset must arm the one-shot ephemeral-OIDC flag for the next sign-in")
    }
}
