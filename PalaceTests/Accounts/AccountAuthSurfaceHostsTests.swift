//
//  AccountAuthSurfaceHostsTests.swift
//  PalaceTests
//
//  Tests for `Account.authSurfaceHosts` — the lowercased set of hosts
//  that constitute an account's auth surface. Consumed by
//  `AuthErrorClassifier.currentAccountHostsProvider` and the two
//  legacy sibling auth-classification sites
//  (`TokenRefreshInterceptor`, `DownloadAuthRetryHandler`) to
//  short-circuit foreign-host 401s as "not our account's session".
//
//  Wall-failure 2026-06-05-pr1018-icarus-cross-host-logout.md.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class AccountAuthSurfaceHostsTests: XCTestCase {

    private var mockImageCache: MockImageCache!

    override func setUp() {
        super.setUp()
        mockImageCache = MockImageCache()
    }

    override func tearDown() {
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - URL-source tests

    /// Catalog URL host must surface — covers a borrow/loans 401 from the
    /// catalog backend (the most common case).
    func testAuthSurfaceHosts_includesCatalogUrlHost() {
        let catalogLink = OPDS2Link(
            href: "https://catalog.example.com/lib/foo",
            rel: "http://opds-spec.org/catalog"
        )
        let publication = makePublication(links: [catalogLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertTrue(account.authSurfaceHosts.contains("catalog.example.com"),
                      "Catalog URL host must appear in authSurfaceHosts so borrow / loans / catalog endpoints are recognized as belonging to this account. Got: \(account.authSurfaceHosts)")
    }

    /// Authentication-document URL host must surface — covers `/patrons/me`
    /// polls and the auth doc fetch path itself.
    func testAuthSurfaceHosts_includesAuthenticationDocumentUrlHost() {
        let authDocLink = OPDS2Link(
            href: "https://auth.example.com/lib/foo/authentication_document",
            type: "application/vnd.opds.authentication.v1.0+json"
        )
        let publication = makePublication(links: [authDocLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertTrue(account.authSurfaceHosts.contains("auth.example.com"),
                      "Authentication document URL host must appear in authSurfaceHosts so /patrons/me polls and auth-doc fetches are recognized as belonging to this account. Got: \(account.authSurfaceHosts)")
    }

    /// Home-page URL host must surface — some libraries serve borrow /
    /// fulfillment from a host that's only listed under the `alternate`
    /// (home-page) link, not the catalog link.
    func testAuthSurfaceHosts_includesHomePageUrlHost() {
        let homeLink = OPDS2Link(
            href: "https://home.example.com/portal",
            rel: "alternate"
        )
        let publication = makePublication(links: [homeLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertTrue(account.authSurfaceHosts.contains("home.example.com"),
                      "Home-page URL host must appear in authSurfaceHosts so portal-served endpoints aren't false-classified as foreign. Got: \(account.authSurfaceHosts)")
    }

    /// Multi-host aggregation — typical account has multiple URLs that
    /// can resolve to multiple hosts. Verify all three contribute and
    /// the set is a union.
    func testAuthSurfaceHosts_unionsAllProvidedHosts() {
        let catalogLink = OPDS2Link(
            href: "https://catalog.example.com/c",
            rel: "http://opds-spec.org/catalog"
        )
        let authDocLink = OPDS2Link(
            href: "https://auth.example.com/a",
            type: "application/vnd.opds.authentication.v1.0+json"
        )
        let homeLink = OPDS2Link(
            href: "https://home.example.com/h",
            rel: "alternate"
        )
        let publication = makePublication(links: [catalogLink, authDocLink, homeLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.authSurfaceHosts,
                       Set(["catalog.example.com", "auth.example.com", "home.example.com"]),
                       "When all three URLs are populated, authSurfaceHosts must be their union. Missing entries would false-block 401s from the missing host as foreign. Got: \(account.authSurfaceHosts)")
    }

    // MARK: - Defensive behaviors

    /// Lowercasing at the producer is a defense-in-depth invariant —
    /// even if a consumer forgets to lowercase, the producer's lowercase
    /// output paired with the consumer's lowercase comparison still
    /// matches. A URL with capitalized host components must still
    /// resolve to a lowercase entry.
    func testAuthSurfaceHosts_lowercasesAtProducer() {
        let catalogLink = OPDS2Link(
            href: "https://Catalog.Example.COM/lib",
            rel: "http://opds-spec.org/catalog"
        )
        let publication = makePublication(links: [catalogLink])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertTrue(account.authSurfaceHosts.contains("catalog.example.com"),
                      "Producer MUST lowercase host entries — a regression that drops the .lowercased() call would still match consumer-side lowercase comparison only when the URL string was already lowercase, which is not guaranteed. Got: \(account.authSurfaceHosts)")
        XCTAssertFalse(account.authSurfaceHosts.contains("Catalog.Example.COM"),
                       "Mixed-case entry must NOT appear in the set — case-sensitive comparison downstream would treat 'Catalog.Example.COM' as foreign to 'catalog.example.com'.")
    }

    /// Cold-launch / anonymous-library case: publication has no URLs at
    /// all. The set must be empty (not crash, not contain garbage).
    /// Empty is the "no info, don't scope" signal consumed by the
    /// classifier's Rule 4b — caller falls back to legacy behavior.
    func testAuthSurfaceHosts_returnsEmptySetWhenAllURLsAbsent() {
        let publication = makePublication() // no links
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.authSurfaceHosts, Set<String>(),
                       "When no URLs are populated, authSurfaceHosts must return an empty set — the cold-launch / anonymous-library signal that tells consumers to fall back to legacy 401 behavior. A non-empty set with garbage entries would false-block real 401s.")
    }

    /// Malformed URL strings (e.g. lacking a host) must not crash and
    /// must not contribute garbage entries. The set should skip them.
    func testAuthSurfaceHosts_skipsMalformedURLs() {
        // OPDS2Link href that's a relative path — URL(string:) builds a
        // URL with nil host. Must be skipped.
        let badCatalog = OPDS2Link(
            href: "/path-only-no-host",
            rel: "http://opds-spec.org/catalog"
        )
        let goodAuthDoc = OPDS2Link(
            href: "https://auth.example.com/lib/foo",
            type: "application/vnd.opds.authentication.v1.0+json"
        )
        let publication = makePublication(links: [badCatalog, goodAuthDoc])
        let account = Account(publication: publication, imageCache: mockImageCache)

        XCTAssertEqual(account.authSurfaceHosts, Set(["auth.example.com"]),
                       "Malformed URL (no host) must NOT contribute to authSurfaceHosts. The good URL must still surface. A regression that lets through nil-host URLs would crash or pollute the set.")
    }

    // MARK: - Helpers

    private func makePublication(
        title: String = "Test Library",
        id: String = "urn:uuid:test",
        description: String? = nil,
        links: [OPDS2Link] = []
    ) -> OPDS2Publication {
        OPDS2Publication(
            links: links,
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: description,
                id: id,
                title: title
            ),
            images: nil
        )
    }
}
