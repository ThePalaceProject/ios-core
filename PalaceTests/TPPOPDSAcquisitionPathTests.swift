import XCTest

@testable import Palace

class TPPOPDSAcquisitionPathTests: XCTestCase {

  let acquisitions: [TPPOPDSAcquisition] = try!
    TPPOPDSEntry(xml:
      TPPXML(data:
        Data.init(contentsOf:
          Bundle.init(for: TPPOPDSAcquisitionPathTests.self)
            .url(forResource: "NYPLOPDSAcquisitionPathEntry", withExtension: "xml")!)))
      .acquisitions;

  func testSimplifiedAdeptEpubAcquisition() {
    let acquisitionPaths: Array<TPPOPDSAcquisitionPath> =
      TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
        forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
        allowedRelations: [.borrow, .openAccess],
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
    let acquisitionWithSampleData = try! Data(contentsOf: bundle.url(forResource: "TPPOPDSAcquisitionPathEntryWithSampleLink", withExtension: "xml")!)
    let entryWithSample = TPPOPDSEntry(xml: TPPXML(data: acquisitionWithSampleData))!
    let bookWithSample = TPPBook(entry: entryWithSample)
    XCTAssertNotNil(bookWithSample)
    XCTAssert(bookWithSample?.defaultAcquisition?.relation != TPPOPDSAcquisitionRelation.sample)
    XCTAssertNotNil(bookWithSample?.sampleAcquisition)
    XCTAssert(bookWithSample?.sampleAcquisition?.relation == TPPOPDSAcquisitionRelation.sample)
    
  }
}
