//
//  TPPOPDSAcquisitionLicensorTests.swift
//  PalaceTests
//
//  PP-5285: an acquisition link's `drm:licensor` names the DRM vendor for the
//  cover labels. A licensor counts only with both a vendor and a client token.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class TPPOPDSAcquisitionLicensorTests: XCTestCase {

    private func acquisition(licensor: String) -> TPPOPDSAcquisition? {
        let xml = """
        <link xmlns="http://www.w3.org/2005/Atom" \
        xmlns:opds="http://opds-spec.org/2010/catalog" \
        xmlns:drm="http://librarysimplified.org/terms/drm" \
        rel="http://opds-spec.org/acquisition/borrow" \
        type="application/atom+xml;type=entry;profile=opds-catalog" \
        href="https://example.com/borrow">\
        <opds:indirectAcquisition type="application/epub+zip"/>\
        \(licensor)\
        </link>
        """
        guard let linkXML = TPPXML.xml(withData: Data(xml.utf8)) else { return nil }
        return TPPOPDSAcquisition.acquisition(withLinkXML: linkXML)
    }

    func testParse_licensorWithVendorAndClientToken_recordsTheVendor() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: """
            <drm:licensor drm:vendor="NYPL"><drm:clientToken>TOKEN</drm:clientToken></drm:licensor>
            """))
        XCTAssertEqual(parsed.licensorVendor, "NYPL")
    }

    func testParse_licensorWithoutClientToken_isIgnored() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: #"<drm:licensor drm:vendor="NYPL"/>"#))
        XCTAssertNil(parsed.licensorVendor)
    }

    func testParse_licensorWithoutVendor_isIgnored() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: """
            <drm:licensor><drm:clientToken>TOKEN</drm:clientToken></drm:licensor>
            """))
        XCTAssertNil(parsed.licensorVendor)
    }

    func testParse_noLicensor_leavesTheVendorNil() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: ""))
        XCTAssertNil(parsed.licensorVendor)
    }

    /// Books in My Books and Holds are rebuilt from the registry's saved
    /// dictionaries, so the vendor has to survive the round trip.
    func testDictionaryRoundTrip_keepsTheVendor() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: """
            <drm:licensor drm:vendor="NYPL"><drm:clientToken>TOKEN</drm:clientToken></drm:licensor>
            """))
        let restored = try XCTUnwrap(TPPOPDSAcquisition.acquisition(withDictionary: parsed.dictionaryRepresentation()))
        XCTAssertEqual(restored.licensorVendor, "NYPL")
    }

    /// Registries saved before the vendor existed have no key for it.
    func testDictionaryWithoutTheVendorKey_stillLoads() throws {
        let parsed = try XCTUnwrap(acquisition(licensor: ""))
        let saved = parsed.dictionaryRepresentation().mutableCopy() as! NSMutableDictionary
        saved.removeObject(forKey: "licensorVendor")
        let restored = try XCTUnwrap(TPPOPDSAcquisition.acquisition(withDictionary: saved))
        XCTAssertNil(restored.licensorVendor)
        XCTAssertEqual(restored.type, parsed.type)
    }
}
