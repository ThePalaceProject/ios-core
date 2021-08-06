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
}
