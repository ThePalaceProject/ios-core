//
//  ManagedLibraryLaunchStepTests.swift
//  PalaceTests
//
//  PP-5070 — two things the decision table alone cannot cover:
//
//  1. The bounded wait. The registry the app hydrates on cold first launch is
//     `bundled_registry.json`, a build-time cut that does NOT contain the
//     partner's libraries, so the configured identifier is unresolvable on
//     exactly the launch this feature exists for. These tests pin that an
//     unresolved configuration waits rather than falling straight through to
//     the picker — and that the wait ends.
//
//  2. The escape hatch. If the configured library is absent from the NETWORK
//     feed too, the registry's single-library endpoint is the only way to
//     resolve it. The payload below is the verbatim production response for
//     the partner's Lower School library, captured 2026-09-22; the test proves
//     the app's own parser accepts it, so the follow-up story can be sized
//     without first building the fetch.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class ManagedLibraryLaunchStepTests: XCTestCase {

    private let lowerId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let limit = ManagedLibraryPreconfigurator.registryWaitLimit

    // MARK: - The launch-step table
    //
    // decision          │ elapsed < limit │ elapsed >= limit
    // ──────────────────┼─────────────────┼──────────────────
    //  apply            │ libraryApplied  │ libraryApplied
    //  noConfiguration  │ presentPicker   │ presentPicker
    //  alreadyApplied   │ presentPicker   │ presentPicker
    //  registryNotLoaded│ waitForRegistry │ presentPicker
    //  unresolved       │ waitForRegistry │ presentPicker

    func testLaunchStep_Apply_SelectsTheLibraryOnBothSidesOfTheDeadline() {
        for elapsed in [0, limit - 0.1, limit, limit + 60] {
            XCTAssertEqual(
                ManagedLibraryPreconfigurator.launchStep(
                    for: .apply(uuid: lowerId), elapsed: elapsed, limit: limit
                ),
                .libraryApplied,
                "elapsed=\(elapsed)"
            )
        }
    }

    func testLaunchStep_NoConfigurationAndAlreadyApplied_NeverWait() {
        // An unmanaged install must not gain a 15-second delay before the
        // picker it has always shown immediately.
        for decision in [ManagedLibraryDecision.noConfiguration, .alreadyApplied] {
            for elapsed in [0, limit - 0.1, limit, limit + 60] {
                XCTAssertEqual(
                    ManagedLibraryPreconfigurator.launchStep(
                        for: decision, elapsed: elapsed, limit: limit
                    ),
                    .presentPicker,
                    "decision=\(decision) elapsed=\(elapsed)"
                )
            }
        }
    }

    func testLaunchStep_PendingDecisions_WaitBeforeTheDeadline() {
        for decision in [ManagedLibraryDecision.registryNotLoaded, .unresolved] {
            for elapsed in [0, 1, limit - 0.01] {
                XCTAssertEqual(
                    ManagedLibraryPreconfigurator.launchStep(
                        for: decision, elapsed: elapsed, limit: limit
                    ),
                    .waitForRegistry,
                    "decision=\(decision) elapsed=\(elapsed)"
                )
            }
        }
    }

    func testLaunchStep_PendingDecisions_FallBackToThePickerAtTheDeadline() {
        // The boundary is inclusive on the picker side: a wait that never ends
        // leaves a misconfigured device with no way to choose a library at all,
        // which is worse than the barrier this feature removes.
        for decision in [ManagedLibraryDecision.registryNotLoaded, .unresolved] {
            for elapsed in [limit, limit + 0.01, limit + 600] {
                XCTAssertEqual(
                    ManagedLibraryPreconfigurator.launchStep(
                        for: decision, elapsed: elapsed, limit: limit
                    ),
                    .presentPicker,
                    "decision=\(decision) elapsed=\(elapsed)"
                )
            }
        }
    }

    func testRegistryWaitLimit_IsLongEnoughToBeWorthHavingAndShortEnoughToEnd() {
        XCTAssertGreaterThanOrEqual(ManagedLibraryPreconfigurator.registryWaitLimit, 5)
        XCTAssertLessThanOrEqual(ManagedLibraryPreconfigurator.registryWaitLimit, 30)
    }

    // MARK: - Single-library registry endpoint (the escape hatch)

    /// Verbatim production response from
    /// `https://registry.palaceproject.io/library/urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e`,
    /// captured 2026-09-22. Kept byte-for-byte rather than hand-trimmed: a
    /// trimmed fixture proves the parser handles a shape the server never sends.
    private static let singleLibraryResponse = """
{"metadata": {"title": "North Shore Country Day Lower School Library", "adobe_vendor_id": "ThePalaceProject"}, "catalogs": [{"metadata": {"id": "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e", "title": "North Shore Country Day Lower School Library", "modified": "2026-09-11T13:43:38Z", "updated": "2026-09-11T13:43:38Z", "description": "serving North Shore Country Day School Library, IL"}, "links": [{"rel": "http://opds-spec.org/catalog", "href": "https://il.thepalaceproject.org/00351977/", "type": "application/atom+xml;profile=opds-catalog;kind=acquisition"}, {"rel": "http://opds-spec.org/auth/document", "href": "https://il.thepalaceproject.org/00351977/authentication_document", "type": "application/vnd.opds.authentication.v1.0+json"}, {"rel": "alternate", "href": "https://www.nscds.org", "type": "text/html"}, {"rel": "http://librarysimplified.org/rel/registry/eligibility", "href": "https://registry.palaceproject.io/library/urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e/eligibility", "type": "application/geo+json"}, {"rel": "http://librarysimplified.org/rel/registry/focus", "href": "https://registry.palaceproject.io/library/urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e/focus", "type": "application/geo+json"}, {"rel": "help", "href": "mailto:jbranahl@nscds.org", "properties": {"https://schema.org/reservationStatus": "https://schema.org/ReservationCancelled"}}, {"rel": "http://librarysimplified.org/rel/designated-agent/copyright", "href": "mailto:jbranahl@nscds.org", "properties": {"https://schema.org/reservationStatus": "https://schema.org/ReservationCancelled"}}], "images": [{"rel": "http://opds-spec.org/image/thumbnail", "href": "https://tpp-prod-library-registry-public.s3.amazonaws.com/logo/681710a7-d1c2-4649-a29d-4fbd08e8861e.png", "type": "image/png"}]}], "links": [{"rel": "self", "href": "https://registry.palaceproject.io/library/urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e", "type": "application/opds+json"}, {"href": "https://registry.palaceproject.io/register", "rel": "register", "type": "application/opds+json;profile=https://librarysimplified.org/rel/profile/directory"}, {"href": "https://registry.palaceproject.io/qa/search", "rel": "search", "type": "application/opensearchdescription+xml"}, {"href": "https://registry.palaceproject.io/library/{uuid}", "rel": "http://librarysimplified.org/rel/registry/library", "type": "application/opds+json", "templated": true}]}
"""

    func testSingleLibraryEndpointPayload_DecodesWithTheAppsOwnRegistryParser() throws {
        let data = Data(Self.singleLibraryResponse.utf8)
        let feed = try OPDS2CatalogsFeed.fromData(data)
        XCTAssertEqual(feed.catalogs.count, 1)
        XCTAssertEqual(feed.catalogs[0].metadata.id, lowerId)
    }

    func testSingleLibraryEndpointPayload_YieldsAnAccountTheAppCanSelect() throws {
        // The two fields the pre-configuration apply path needs are the two this
        // payload must carry: a uuid to key the selection and a catalog URL to
        // point the feed at.
        let feed = try OPDS2CatalogsFeed.fromData(Data(Self.singleLibraryResponse.utf8))
        let account = Account(publication: feed.catalogs[0], imageCache: MockImageCache())

        XCTAssertEqual(account.uuid, lowerId)
        XCTAssertEqual(account.name, "North Shore Country Day Lower School Library")
        XCTAssertEqual(account.catalogUrl, "https://il.thepalaceproject.org/00351977/")
        XCTAssertNotNil(account.authenticationDocumentUrl)
    }

    func testSingleLibraryEndpointPayload_ResolvesThroughTheConfiguredIdentifier() throws {
        // Closes the loop: the identifier an administrator types into their MDM
        // is the identifier this payload resolves to, with no transformation
        // beyond the documented urn normalization.
        let feed = try OPDS2CatalogsFeed.fromData(Data(Self.singleLibraryResponse.utf8))
        let typedByAdministrator = "681710A7-D1C2-4649-A29D-4FBD08E8861E"

        XCTAssertEqual(
            ManagedAppConfiguration.canonicalLibraryId(typedByAdministrator),
            feed.catalogs[0].metadata.id
        )
    }
}
