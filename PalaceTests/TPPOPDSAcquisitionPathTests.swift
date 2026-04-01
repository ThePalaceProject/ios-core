import XCTest

@testable import Palace

class TPPOPDSAcquisitionPathTests: XCTestCase {

    var acquisitions: [TPPOPDSAcquisition]!

    override func setUp() {
        super.setUp()
        let bundle = Bundle(for: TPPOPDSAcquisitionPathTests.self)
        guard let url = bundle.url(forResource: "NYPLOPDSAcquisitionPathEntry", withExtension: "xml"),
              let data = try? Data(contentsOf: url),
              let xml = TPPXML(data: data),
              let entry = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to parse test XML")
            return
        }
        acquisitions = entry.acquisitions
    }

    func testSimplifiedAdeptEpubAcquisition() {
        let acquisitionPaths: [TPPOPDSAcquisitionPath] =
            TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
                forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
                allowedRelations: TPPOPDSAcquisitionRelationSet([.borrow, .openAccess]).rawValue,
                acquisitions: acquisitions)

        XCTAssert(acquisitionPaths.count == 2)

        XCTAssert(acquisitionPaths[0].relation == TPPOPDSAcquisitionRelation.borrow)
        XCTAssert(acquisitionPaths[0].types == [
            "application/atom+xml;type=entry;profile=opds-catalog",
            "application/vnd.adobe.adept+xml",
            "application/epub+zip"
        ])

        XCTAssert(acquisitionPaths[1].relation == TPPOPDSAcquisitionRelation.borrow)
        XCTAssert(acquisitionPaths[1].types == [
            "application/atom+xml;type=entry;profile=opds-catalog",
            "application/pdf"
        ])
    }

    func testSampleLinkInAcquisitions() {
        // TPPOPDSAcquisitionPathEntryWithSampleLink.xml contains a sample link
        let bundle = Bundle(for: TPPOPDSAcquisitionPathTests.self)
        guard let url = bundle.url(forResource: "TPPOPDSAcquisitionPathEntryWithSampleLink", withExtension: "xml"),
              let data = try? Data(contentsOf: url),
              let xml = TPPXML(data: data),
              let entryWithSample = TPPOPDSEntry(xml: xml) else {
            XCTFail("Failed to parse test XML with sample link")
            return
        }
        let bookWithSample = TPPBook(entry: entryWithSample)
        XCTAssertNotNil(bookWithSample)
        XCTAssert(bookWithSample?.defaultAcquisition?.relation != TPPOPDSAcquisitionRelation.sample)
        XCTAssertNotNil(bookWithSample?.sampleAcquisition)
        XCTAssert(bookWithSample?.sampleAcquisition?.relation == TPPOPDSAcquisitionRelation.sample)
    }
}
