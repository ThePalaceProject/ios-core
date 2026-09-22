//
//  ManagedAppConfigurationTests.swift
//  PalaceTests
//
//  PP-5070 — the parse surface an MDM administrator types into. Every case here
//  is a spelling a real administrator can plausibly produce; the point is that
//  a wrong one reads as "no configuration" rather than as a library the app
//  cannot resolve.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ManagedAppConfigurationTests: XCTestCase {

    private let lowerSchoolId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"

    // MARK: - Identifier normalization

    func testCanonicalLibraryId_WhenPrefixedLowercase_IsUnchanged() {
        XCTAssertEqual(ManagedAppConfiguration.canonicalLibraryId(lowerSchoolId), lowerSchoolId)
    }

    func testCanonicalLibraryId_WhenBareUUID_GainsURNPrefix() {
        XCTAssertEqual(
            ManagedAppConfiguration.canonicalLibraryId("681710a7-d1c2-4649-a29d-4fbd08e8861e"),
            lowerSchoolId
        )
    }

    func testCanonicalLibraryId_WhenUppercaseAndPrefixMixedCase_IsLowercasedToMatchAccountUUID() {
        XCTAssertEqual(
            ManagedAppConfiguration.canonicalLibraryId("URN:UUID:681710A7-D1C2-4649-A29D-4FBD08E8861E"),
            lowerSchoolId
        )
    }

    func testCanonicalLibraryId_WhenPastedWithSurroundingWhitespace_IsTrimmed() {
        XCTAssertEqual(
            ManagedAppConfiguration.canonicalLibraryId("  \n\t\(lowerSchoolId)  \n"),
            lowerSchoolId
        )
    }

    func testCanonicalLibraryId_WhenWhitespaceFollowsThePrefix_IsStillResolved() {
        XCTAssertEqual(
            ManagedAppConfiguration.canonicalLibraryId("urn:uuid: 681710a7-d1c2-4649-a29d-4fbd08e8861e"),
            lowerSchoolId
        )
    }

    func testCanonicalLibraryId_WhenNotAUUID_IsRejectedRatherThanPassedThrough() {
        // A pass-through would produce a "configured" library that can never
        // resolve, which reads to an administrator as the feature being broken
        // rather than as their value being wrong.
        XCTAssertNil(ManagedAppConfiguration.canonicalLibraryId("North Shore Lower School"))
        XCTAssertNil(ManagedAppConfiguration.canonicalLibraryId("urn:uuid:not-a-uuid"))
        XCTAssertNil(ManagedAppConfiguration.canonicalLibraryId(""))
        XCTAssertNil(ManagedAppConfiguration.canonicalLibraryId("   "))
    }

    func testCanonicalLibraryId_WhenUUIDIsTruncated_IsRejected() {
        XCTAssertNil(ManagedAppConfiguration.canonicalLibraryId("681710a7-d1c2-4649-a29d"))
    }

    // MARK: - Catalog URL

    func testNormalizedCatalogURL_AcceptsHTTPSAndPreservesThePath() {
        let url = ManagedAppConfiguration.normalizedCatalogURL("https://il.thepalaceproject.org/00351977/")
        XCTAssertEqual(url?.absoluteString, "https://il.thepalaceproject.org/00351977/")
    }

    func testNormalizedCatalogURL_RejectsCleartextHTTP() {
        XCTAssertNil(ManagedAppConfiguration.normalizedCatalogURL("http://il.thepalaceproject.org/00351977/"))
    }

    func testNormalizedCatalogURL_RejectsAStringWithNoHost() {
        XCTAssertNil(ManagedAppConfiguration.normalizedCatalogURL("00351977"))
        XCTAssertNil(ManagedAppConfiguration.normalizedCatalogURL("https://"))
    }

    // MARK: - Catalog URL matching

    func testCatalogURLMatch_IgnoresATrailingSlashDifference() throws {
        let configured = try XCTUnwrap(ManagedAppConfiguration.normalizedCatalogURL("https://il.thepalaceproject.org/00351977"))
        XCTAssertTrue(
            ManagedAppConfiguration.catalogURL("https://il.thepalaceproject.org/00351977/", matches: configured)
        )
    }

    func testCatalogURLMatch_IgnoresHostCase() throws {
        let configured = try XCTUnwrap(ManagedAppConfiguration.normalizedCatalogURL("https://IL.ThePalaceProject.ORG/00351977/"))
        XCTAssertTrue(
            ManagedAppConfiguration.catalogURL("https://il.thepalaceproject.org/00351977/", matches: configured)
        )
    }

    func testCatalogURLMatch_DistinguishesSiblingDivisionsOnTheSameHost() throws {
        // The three divisions differ only in the last path component
        // (00351977 / 00351977b / 00351977c). A matcher that compared host
        // alone would put every student in the Lower School.
        let configured = try XCTUnwrap(ManagedAppConfiguration.normalizedCatalogURL("https://il.thepalaceproject.org/00351977/"))
        XCTAssertFalse(
            ManagedAppConfiguration.catalogURL("https://il.thepalaceproject.org/00351977b/", matches: configured)
        )
        XCTAssertFalse(
            ManagedAppConfiguration.catalogURL("https://il.thepalaceproject.org/00351977c/", matches: configured)
        )
    }

    func testCatalogURLMatch_RejectsADifferentHostWithTheSamePath() throws {
        let configured = try XCTUnwrap(ManagedAppConfiguration.normalizedCatalogURL("https://il.thepalaceproject.org/00351977/"))
        XCTAssertFalse(
            ManagedAppConfiguration.catalogURL("https://evil.example.com/00351977/", matches: configured)
        )
    }

    func testCatalogURLMatch_WhenRegistryEntryHasNoCatalogURL_DoesNotMatch() throws {
        let configured = try XCTUnwrap(ManagedAppConfiguration.normalizedCatalogURL("https://il.thepalaceproject.org/00351977/"))
        XCTAssertFalse(ManagedAppConfiguration.catalogURL(nil, matches: configured))
    }

    // MARK: - Dictionary parsing

    func testPreconfiguration_WhenDictionaryHasNeitherKey_IsNil() {
        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: ["someOtherKey": "value"]))
    }

    func testPreconfiguration_WhenOnlyKeysPresentAreUnusable_IsNilRatherThanEmpty() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": "nonsense",
            "defaultLibraryCatalogUrl": "ftp://nope"
        ])
        XCTAssertNil(parsed)
    }

    func testPreconfiguration_WhenIdentifierIsNotAString_IsIgnored() {
        // MDM payloads are administrator-authored plists; a number where a
        // string belongs is a realistic mistake and must not trap.
        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": 681710
        ]))
    }

    func testPreconfiguration_WhenOnlyCatalogURLSupplied_CarriesURLWithNoIdentifier() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryCatalogUrl": "https://il.thepalaceproject.org/00351977/"
        ])
        XCTAssertNil(parsed?.libraryId)
        XCTAssertEqual(parsed?.catalogURL?.absoluteString, "https://il.thepalaceproject.org/00351977/")
    }

    func testPreconfiguration_ReadsThroughTheAppleManagedConfigurationKey() {
        let suite = UserDefaults(suiteName: "ManagedAppConfigurationTests.read")!
        defer { suite.removePersistentDomain(forName: "ManagedAppConfigurationTests.read") }
        suite.set(["defaultLibraryId": lowerSchoolId], forKey: "com.apple.configuration.managed")

        XCTAssertEqual(
            ManagedAppConfiguration.libraryPreconfiguration(defaults: suite)?.libraryId,
            lowerSchoolId
        )
    }

    func testPreconfiguration_OnAnUnmanagedInstall_IsNil() {
        let suite = UserDefaults(suiteName: "ManagedAppConfigurationTests.unmanaged")!
        defer { suite.removePersistentDomain(forName: "ManagedAppConfigurationTests.unmanaged") }
        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(defaults: suite))
    }

    // MARK: - Fingerprint

    func testFingerprint_DistinguishesTheThreeDivisions() {
        let ids = [
            "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e", // Lower
            "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07", // Middle
            "urn:uuid:511def8d-0319-41bb-89e2-4902c017c810"  // Upper
        ]
        let fingerprints = Set(ids.map {
            ManagedLibraryPreconfiguration(libraryId: $0, catalogURL: nil).fingerprint
        })
        XCTAssertEqual(fingerprints.count, 3)
    }

    func testFingerprint_IsStableAcrossEquivalentSpellingsOfTheSameValue() {
        // An administrator who re-types the same UUID in a different case must
        // not cause a re-apply on the next launch.
        let a = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": "681710A7-D1C2-4649-A29D-4FBD08E8861E"
        ])
        let b = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": " urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e "
        ])
        XCTAssertEqual(a?.fingerprint, b?.fingerprint)
    }

    func testFingerprint_ChangesWhenOnlyTheCatalogURLChanges() {
        let a = ManagedLibraryPreconfiguration(
            libraryId: nil,
            catalogURL: URL(string: "https://il.thepalaceproject.org/00351977/")
        )
        let b = ManagedLibraryPreconfiguration(
            libraryId: nil,
            catalogURL: URL(string: "https://il.thepalaceproject.org/00351977b/")
        )
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }
}
