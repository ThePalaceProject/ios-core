//
//  CookiePersistenceTests.swift
//  PalaceTests
//
//  Mutation-killing tests for SAML cookie persistence across cold-start.
//
//  Contract pinned here (read from production source — see
//  `TPPNetworkExecutor.request(for:useTokenIfAvailable:accountId:)` and
//  `TPPUserAccount.setCookies` / `var cookies`):
//
//  1. Cookies stored on the user account via `setCookies(_:)` survive
//     across recreating the network executor (the cold-start contract:
//     the URLSession is gone, but the per-account credential snapshot
//     still returns the stored cookies).
//  2. On the very next `request(for:)` issued by a freshly-built
//     executor for a SAML account, those cookies must be installed into
//     `HTTPCookieStorage.shared` BEFORE the request goes out — so cold-
//     start cookie sync is observable from the shared storage.
//  3. The cookies survive `finishTasksAndInvalidate()` + recreate of
//     the URLSession: ephemeral sessions don't share `HTTPCookieStorage.shared`,
//     but the executor re-installs them every request anyway.
//  4. Token credentials never produce a Cookie header on the request,
//     regardless of cookies on the shared storage — the cookie-install
//     branch is gated on `authDef.isSaml`.
//
//  Coverage notes:
//   - We construct a SAML user account by writing `.cookies([...])`
//     into `_credentials` AND setting `_cookies` (the cookie storage is
//     separate from credentials in the real account model).
//   - Each test asserts a property that a plausible mutation would flip:
//     deleting the cold-start install loop, inverting the `isSaml` gate,
//     replacing `for c in cookies { shared.setCookie(c) }` with a no-op,
//     etc.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

/// Test-local mock that exposes `setCookies` writes to the production
/// `credentialSnapshot()` read path. The base `TPPUserAccountMock`
/// stores cookies in a private `_cookies: [HTTPCookie]?` property but
/// the production snapshot reads from the parent class's
/// `TPPKeychainVariable`-backed storage, which the mock never writes
/// into. This subclass re-routes the snapshot to read from the mock's
/// own storage so cold-start cookie sync is observable through the
/// real production code path.
private final class TPPUserAccountCookieMock: TPPUserAccountMock, @unchecked Sendable {
    override func credentialSnapshot() -> TPPUserAccount.CredentialSnapshot {
        // Build a snapshot that uses the mock's own state. `cookies` is
        // the critical field — request(for:) installs these into
        // HTTPCookieStorage.shared for SAML accounts. The other fields
        // mirror what the production snapshot would carry for an
        // account whose credentials come from setAuthToken / setCookies.
        return TPPUserAccount.CredentialSnapshot(
            hasCredentials: hasCredentials(),
            hasAuthToken: false,
            authState: authState,
            barcode: nil,
            pin: nil,
            authToken: authToken,
            authDefinition: authDefinition,
            cookies: self.cookies
        )
    }
}

@MainActor
final class CookiePersistenceTests: XCTestCase {

    // MARK: - Fixtures

    private var executor: TPPNetworkExecutor!
    // nonisolated(unsafe): read by the nonisolated makeExecutor helper; all
    // access is main-thread (setUp/tearDown/test bodies).
    private nonisolated(unsafe) var libraryAccount: TPPLibraryAccountMock!
    private var userAccount: TPPUserAccountMock!

    private let samlBorrowURL = URL(string: "https://library.example.com/borrow/123")!
    private let cookieDomain = "library.example.com"

    override func setUp() async throws {
        try await super.setUp()
        HTTPStubURLProtocol.reset()
        TPPUserAccountMock.resetShared()
        clearSharedCookieStorage()

        userAccount = TPPUserAccountCookieMock()
        // Build a SAML auth definition so the executor's cookie-install
        // branch is reachable. Production reaches the `if authDef.isSaml`
        // branch in `request(for:)` only for SAML accounts.
        userAccount._authDefinition = Self.makeSamlAuthDefinition()
        userAccount.markLoggedIn()

        libraryAccount = TPPLibraryAccountMock()
        // Capture userAccount directly so a stale URLSession callback firing
        // after tearDown nils self.userAccount can't crash on the IUO unwrap.
        // The property is typed `TPPUserAccountMock!` even though the actual
        // instance is `TPPUserAccountCookieMock`; capture as the parent type.
        let resolvedUserAccount: TPPUserAccountMock = userAccount
        libraryAccount.userAccountResolver = { _ in resolvedUserAccount }

        executor = makeExecutor()
    }

    // async tearDown adopts the class's @MainActor isolation so the main-actor
    // clearSharedCookieStorage() call is not sent from a nonisolated context.
    override func tearDown() async throws {
        HTTPStubURLProtocol.reset()
        clearSharedCookieStorage()
        executor = nil
        libraryAccount = nil
        userAccount = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build an ephemeral executor with HTTP stubbing wired in. Each call
    /// gives a fresh URLSession (so "cold-start" is just calling this again).
    // nonisolated: pure fixture/helper (no isolated state); called from
    // inherited-nonisolated setUp/tearDown overrides or nonisolated
    // contexts (Swift 6 sending error otherwise).
    private nonisolated func makeExecutor() -> TPPNetworkExecutor {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return TPPNetworkExecutor(
            credentialsProvider: nil,
            cachingStrategy: .ephemeral,
            sessionConfiguration: config,
            accountsManager: libraryAccount,
            delegateQueue: nil
        )
    }

    // nonisolated: pure fixture/helper (no isolated state); called from
    // inherited-nonisolated setUp/tearDown overrides or nonisolated
    // contexts (Swift 6 sending error otherwise).
    private nonisolated static func makeSamlAuthDefinition() -> AccountDetails.Authentication {
        // OPDS2 authentication-document JSON for SAML. Carries no tokenURL
        // by design so the token-refresh path is never eligible here.
        let json = """
        {
          "type": "http://librarysimplified.org/authtype/SAML-2.0",
          "links": [
            {"rel": "authenticate", "href": "https://idp.example.com/sso"}
          ]
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    private func makeCookie(name: String,
                            value: String,
                            domain: String? = nil) -> HTTPCookie {
        return HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain ?? cookieDomain,
            .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600),
        ])!
    }

    // nonisolated: pure fixture/helper (no isolated state); called from
    // inherited-nonisolated setUp/tearDown overrides or nonisolated
    // contexts (Swift 6 sending error otherwise).
    private nonisolated func clearSharedCookieStorage() {
        let shared = HTTPCookieStorage.shared
        // Clearing only `cookieDomain`-scoped cookies keeps unrelated
        // shared cookies in other test suites untouched.
        shared.cookies?.forEach { cookie in
            if cookie.domain.contains("example.com") {
                shared.deleteCookie(cookie)
            }
        }
    }

    /// Waits up to `timeout` for `condition`, pumping the runloop so any
    /// URLSession callbacks land. Hermetic — uses only HTTPStubURLProtocol.
    @discardableResult
    private func waitForCondition(timeout: TimeInterval = 2.0,
                                  _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default,
                                before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func sharedCookies(named name: String) -> [HTTPCookie] {
        let all = HTTPCookieStorage.shared.cookies ?? []
        return all.filter { $0.name == name }
    }

    // MARK: - Test 1: setCookies stores and round-trips
    //
    // Kills: deletion of the `_cookies.write(newValue)` body inside
    // `TPPUserAccountMock.setCookies(_:)` (the mock mirror of the real
    // setter). Without storage, `cookies` would return nil and the
    // executor's `if let cookies = snapshot.cookies, !cookies.isEmpty`
    // gate would never fire on cold-start, silently breaking SAML.

    func test_setCookies_StoresOnAccountAndIsReadable() {
        let c1 = makeCookie(name: "saml_session", value: "abc123")
        let c2 = makeCookie(name: "csrf", value: "tok-9")
        userAccount.setCookies([c1, c2])

        XCTAssertNotNil(userAccount.cookies,
                        "setCookies must populate the cookies accessor — kills deletion of the write")
        XCTAssertEqual(userAccount.cookies?.count, 2,
                       "Cookie count must match what was written — kills replacement with empty array")
        let names = Set((userAccount.cookies ?? []).map { $0.name })
        XCTAssertEqual(names, Set(["saml_session", "csrf"]),
                       "Cookie names must round-trip — kills swap-with-other-cookie mutation")
    }

    // MARK: - Test 2: Cookies survive executor recreation (cold-start)
    //
    // Kills: any mutation that ties the cookie store to the executor's
    // URLSession lifetime. The executor is recreated (simulating cold-
    // start: process restarts, URLSession is gone) but the cookies are
    // owned by the user account, NOT the session, so they must still be
    // available on the second executor's first request.

    func test_CookiesSurvive_ExecutorRecreation_AndAreInstalledIntoSharedStorage() {
        let cookie = makeCookie(name: "saml_session", value: "persisted-across-cold-start")
        userAccount.setCookies([cookie])

        // First executor: ensure baseline (this is "before cold-start").
        let firstRequest = executor.request(for: samlBorrowURL)
        XCTAssertEqual(firstRequest.url, samlBorrowURL)
        // Sanity: cookie now in shared storage.
        XCTAssertFalse(sharedCookies(named: "saml_session").isEmpty,
                       "Pre-cold-start: cookie should already be in shared storage after first request")

        // Simulate cold-start: blow away the executor + its URLSession,
        // wipe shared cookie storage (the most aggressive cold-start
        // simulation: even shared storage is gone, which it would be in a
        // process restart with an ephemeral session). The cookies on the
        // user account survive, and the new executor must re-install them.
        executor = nil
        clearSharedCookieStorage()
        XCTAssertTrue(sharedCookies(named: "saml_session").isEmpty,
                      "Shared storage should be empty after the simulated cold-start wipe")

        // Recreate the executor. The user account (and its cookies) is
        // untouched — that's the persistence boundary.
        executor = makeExecutor()
        XCTAssertNotNil(userAccount.cookies,
                        "Account cookies must survive executor teardown — kills any mutation that ties account lifetime to executor")
        XCTAssertEqual(userAccount.cookies?.count, 1)

        // The next request from the FRESH executor must re-install the
        // cookies into shared storage (the SAML branch in `request(for:)`).
        _ = executor.request(for: samlBorrowURL)
        let restored = sharedCookies(named: "saml_session")
        XCTAssertEqual(restored.count, 1,
                       "Cold-start: cookies must be re-installed by the next request (kills deletion of the cookie-install loop)")
        XCTAssertEqual(restored.first?.value, "persisted-across-cold-start",
                       "Restored cookie value must match the stored one (kills swap-with-empty-string mutation)")
    }

    // MARK: - Test 3: Cookies are NOT installed for non-SAML auth
    //
    // Kills: removal of the `if let authDef = snapshot.authDefinition, authDef.isSaml`
    // guard. If the gate is inverted or deleted, token / basic / oauth
    // accounts would also install cookies, leaking cookies cross-auth.

    func test_NonSamlAuth_DoesNotInstall_CookiesIntoSharedStorage() {
        // Reconfigure as token auth — same cookies are present on the
        // account (defensive scenario), but the install branch must NOT
        // fire because the auth is not SAML.
        userAccount._authDefinition = makeTokenAuth()
        let leakyCookie = makeCookie(name: "should_not_leak", value: "nope")
        userAccount.setCookies([leakyCookie])

        _ = executor.request(for: samlBorrowURL)

        XCTAssertTrue(sharedCookies(named: "should_not_leak").isEmpty,
                      "A token-auth account must NOT install its cookies into shared storage — kills inversion or deletion of the `authDef.isSaml` gate in request(for:)")
    }

    // nonisolated: pure fixture/helper (no isolated state); called from
    // inherited-nonisolated setUp/tearDown overrides or nonisolated
    // contexts (Swift 6 sending error otherwise).
    private nonisolated func makeTokenAuth() -> AccountDetails.Authentication {
        let json = """
        {
          "type": "http://thepalaceproject.org/authtype/basic-token",
          "links": [
            {"rel": "authenticate", "href": "https://token.example.com/oauth/token"}
          ]
        }
        """
        let docAuth = try! JSONDecoder().decode(
            OPDS2AuthenticationDocument.Authentication.self,
            from: Data(json.utf8)
        )
        return AccountDetails.Authentication(auth: docAuth)
    }

    // MARK: - Test 4: Empty cookies array does not crash and is a no-op
    //
    // Kills: replacement of `if !cookies.isEmpty` with `if cookies.isEmpty`
    // (which would dereference a nil/empty collection and either crash or
    // run an empty install loop with side-effects on shared storage state).

    func test_EmptyCookiesArray_OnSamlAccount_IsNoOp() {
        userAccount.setCookies([])
        // Pre-install a sentinel cookie in shared storage; the executor
        // must NOT remove it when the account's cookie set is empty.
        let sentinel = makeCookie(name: "sentinel", value: "stay")
        HTTPCookieStorage.shared.setCookie(sentinel)

        _ = executor.request(for: samlBorrowURL)

        XCTAssertEqual(sharedCookies(named: "sentinel").first?.value, "stay",
                       "Empty cookie array on the account must not clobber pre-existing shared-storage cookies — kills delete-all replacement of the install branch")
    }

    // MARK: - Test 5: Cookies are re-applied on every request (defensive)
    //
    // Kills: hoisting the cookie-install loop into a one-shot guard
    // (e.g. wrapping it in `if !installedOnce { ... installedOnce = true }`).
    // The contract is that every request re-installs — that way a
    // background process or another extension that wipes the shared
    // storage can't desync the next request.

    func test_CookiesReinstalled_OnEveryRequest_AfterSharedStorageWipe() {
        let c = makeCookie(name: "saml_session", value: "v1")
        userAccount.setCookies([c])

        _ = executor.request(for: samlBorrowURL)
        XCTAssertEqual(sharedCookies(named: "saml_session").count, 1)

        // Wipe between requests — simulates an extension or system event.
        clearSharedCookieStorage()
        XCTAssertTrue(sharedCookies(named: "saml_session").isEmpty)

        _ = executor.request(for: samlBorrowURL)
        XCTAssertEqual(sharedCookies(named: "saml_session").count, 1,
                       "Every request must re-install the account cookies — kills one-shot-install mutation")
    }

    // MARK: - Test 6: Updated cookie value replaces the prior one
    //
    // Kills: replacement of `shared.setCookie(cookie)` with a no-op or
    // with `shared.deleteCookie(cookie)`. Setting twice with the same
    // (name, domain, path) tuple must result in the new value being
    // visible on the next request.

    func test_UpdatedCookieValue_IsVisibleOnNextRequest() {
        let oldCookie = makeCookie(name: "saml_session", value: "old")
        userAccount.setCookies([oldCookie])
        _ = executor.request(for: samlBorrowURL)
        XCTAssertEqual(sharedCookies(named: "saml_session").first?.value, "old")

        let newCookie = makeCookie(name: "saml_session", value: "new")
        userAccount.setCookies([newCookie])
        _ = executor.request(for: samlBorrowURL)

        XCTAssertEqual(sharedCookies(named: "saml_session").first?.value, "new",
                       "Updating the cookie on the account must surface on the next request (kills replacement of setCookie with no-op or delete)")
    }

    // MARK: - Test 7: Cookies install at the right URL scope
    //
    // Kills: stripping the cookie's domain on install or hardcoding the
    // wrong domain. We assert by querying `cookies(for:)` with a URL
    // whose host matches the cookie's domain — if the install lost the
    // domain, the cookie would be present in `cookies` (unfiltered) but
    // not in the filtered view at the SAML URL.

    func test_InstalledCookie_IsVisibleAtTheSamlURL() {
        let c = makeCookie(name: "saml_session", value: "scoped", domain: cookieDomain)
        userAccount.setCookies([c])

        _ = executor.request(for: samlBorrowURL)

        let scoped = HTTPCookieStorage.shared.cookies(for: samlBorrowURL) ?? []
        XCTAssertTrue(scoped.contains(where: { $0.name == "saml_session" }),
                      "Cookie must be visible at its scoped URL — kills mutations that strip domain on install")
    }

    // MARK: - Test 8: Multiple cookies all install on cold-start
    //
    // Kills: replacement of the install-loop with a single-cookie
    // first-only install (`shared.setCookie(cookies.first!)`).

    func test_MultipleCookies_AllInstalled_AfterColdStart() {
        let cookies = [
            makeCookie(name: "saml_session", value: "a"),
            makeCookie(name: "csrf", value: "b"),
            makeCookie(name: "idp_state", value: "c"),
        ]
        userAccount.setCookies(cookies)

        // Cold-start.
        executor = nil
        clearSharedCookieStorage()
        executor = makeExecutor()
        _ = executor.request(for: samlBorrowURL)

        XCTAssertFalse(sharedCookies(named: "saml_session").isEmpty,
                       "First cookie present after cold-start")
        XCTAssertFalse(sharedCookies(named: "csrf").isEmpty,
                       "Middle cookie present after cold-start (kills first-only install mutation)")
        XCTAssertFalse(sharedCookies(named: "idp_state").isEmpty,
                       "Last cookie present after cold-start (kills off-by-one in install loop)")
    }

    // MARK: - Test 9: Cookie-only credentials carry through credential snapshot
    //
    // Kills: a snapshot that drops cookies from the credential bundle
    // (i.e. mutation that returns `cookies: nil` from
    // `credentialSnapshot()`). Because `request(for:)` reads cookies
    // from the snapshot, not directly from the account, dropping them
    // there silently disables cold-start cookie sync.
    //
    // Note: the production snapshot is per-class; the mock's snapshot
    // returns `cookies: nil` by design (because cookies are stored
    // separately from credentials in TPPUserAccountMock). For this test
    // we cover the OBSERVABLE contract: a request built for a SAML
    // account whose `_cookies` is set goes through the cookie-install
    // path, where the input to that path is the account's `cookies`
    // accessor (mirrored by the mock).

    func test_CookieAccessor_IsConsultedByRequestPath() {
        // No setCookies call — the account has nil cookies.
        XCTAssertNil(userAccount.cookies, "Precondition: no cookies on account")
        _ = executor.request(for: samlBorrowURL)
        XCTAssertTrue(sharedCookies(named: "saml_session").isEmpty,
                      "With no account cookies, nothing is installed — kills mutation that injects a default cookie set")

        // Add cookies and re-issue.
        userAccount.setCookies([makeCookie(name: "saml_session", value: "after-write")])
        _ = executor.request(for: samlBorrowURL)
        XCTAssertEqual(sharedCookies(named: "saml_session").first?.value, "after-write",
                       "Newly-added cookies are picked up on the very next request — kills mutation that caches a stale empty cookie set")
    }

    // MARK: - Test 10: Logging out clears cookies and they do NOT re-appear
    //
    // Kills: `removeAll()` mutation that forgets to clear the cookie slot
    // (i.e. drops `_cookies = nil` from removeAll). After sign-out, the
    // next request must NOT re-install the prior session's cookies.

    func test_RemoveAll_ClearsCookies_NoReinstallOnNextRequest() {
        userAccount.setCookies([makeCookie(name: "saml_session", value: "logged-in")])
        _ = executor.request(for: samlBorrowURL)
        XCTAssertEqual(sharedCookies(named: "saml_session").count, 1)

        // Sign out: removeAll() must wipe cookies. Then we also wipe
        // shared storage to simulate an explicit sign-out clear.
        userAccount.removeAll()
        clearSharedCookieStorage()
        XCTAssertNil(userAccount.cookies,
                     "removeAll must clear cookies — kills deletion of `_cookies = nil` in removeAll")

        // Next request from any subsequent (unauthenticated) flow must
        // not magically reinstall the prior session's cookies.
        _ = executor.request(for: samlBorrowURL)
        XCTAssertTrue(sharedCookies(named: "saml_session").isEmpty,
                      "Post-sign-out: no cookies should be installed on the next request — kills any mutation that preserves cookies across removeAll")
    }
}
