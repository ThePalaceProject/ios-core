import XCTest
@testable import Palace

class TPPBookContentTypeTests: XCTestCase {

  // MARK: - TPPBookContentType.from(mimeType:)

  func test_from_epubZipMimeType_returnsEpub() {
    let result = TPPBookContentType.from(mimeType: "application/epub+zip")
    XCTAssertEqual(result, .epub)
  }

  func test_from_octetStreamMimeType_returnsEpub() {
    let result = TPPBookContentType.from(mimeType: "application/octet-stream")
    XCTAssertEqual(result, .epub)
  }

  func test_from_pdfMimeType_returnsPdf() {
    let result = TPPBookContentType.from(mimeType: "application/pdf")
    XCTAssertEqual(result, .pdf)
  }

  func test_from_audiobookJsonMimeType_returnsAudiobook() {
    let result = TPPBookContentType.from(mimeType: "application/audiobook+json")
    XCTAssertEqual(result, .audiobook)
  }

  func test_from_nilMimeType_returnsUnsupported() {
    let result = TPPBookContentType.from(mimeType: nil)
    XCTAssertEqual(result, .unsupported)
  }

  func test_from_unknownMimeType_returnsUnsupported() {
    let result = TPPBookContentType.from(mimeType: "video/mp4")
    XCTAssertEqual(result, .unsupported)
  }

  func test_from_emptyMimeType_returnsUnsupported() {
    let result = TPPBookContentType.from(mimeType: "")
    XCTAssertEqual(result, .unsupported)
  }

  // MARK: - TPPBookContentTypeConverter

  func test_converter_epub_returnsEpub() {
    XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .epub), "Epub")
  }

  func test_converter_audiobook_returnsAudioBook() {
    XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .audiobook), "AudioBook")
  }

  func test_converter_pdf_returnsPDF() {
    XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .pdf), "PDF")
  }

  func test_converter_unsupported_returnsUnsupported() {
    XCTAssertEqual(TPPBookContentTypeConverter.stringValue(of: .unsupported), "Unsupported")
  }

  // MARK: - OPDS Publication type (OPDS2 feeds)

  func test_opdsPublicationType_isInSupportedTypes() {
    let types = TPPOPDSAcquisitionPath.supportedTypes()
    XCTAssertTrue(types.contains("application/opds-publication+json"),
                  "supportedTypes() must include application/opds-publication+json for OPDS2 feeds")
  }

  func test_opdsPublicationType_withDirectEpubIndirect_producesEpubPath() {
    // Simulates an Accessible EPUB Test book from OPDS2 feed:
    // borrow link type=opds-publication+json, indirectAcquisition=[epub+zip]
    let indirect = TPPOPDSIndirectAcquisition(type: "application/epub+zip", indirectAcquisitions: [])
    let acquisition = TPPOPDSAcquisition(
      relation: .borrow,
      type: "application/opds-publication+json",
      hrefURL: URL(string: "https://example.com/borrow")!,
      indirectAcquisitions: [indirect],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
      forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
      allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
      acquisitions: [acquisition]
    )

    XCTAssertFalse(paths.isEmpty, "Should find supported path for opds-publication+json → epub+zip")
    if let path = paths.first {
      XCTAssertEqual(path.types.last, "application/epub+zip")
      let contentType = TPPBookContentType.from(mimeType: path.types.last)
      XCTAssertEqual(contentType, .epub)
    }
  }

  func test_opdsPublicationType_withLCPEpubIndirect_producesEpubPath() {
    // Simulates an ODL ebook from OPDS2 feed:
    // borrow link type=opds-publication+json, indirectAcquisition=[LCP → epub+zip]
    let innerIndirect = TPPOPDSIndirectAcquisition(type: "application/epub+zip", indirectAcquisitions: [])
    let lcpIndirect = TPPOPDSIndirectAcquisition(type: "application/vnd.readium.lcp.license.v1.0+json", indirectAcquisitions: [innerIndirect])
    let acquisition = TPPOPDSAcquisition(
      relation: .borrow,
      type: "application/opds-publication+json",
      hrefURL: URL(string: "https://example.com/borrow")!,
      indirectAcquisitions: [lcpIndirect],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let paths = TPPOPDSAcquisitionPath.supportedAcquisitionPaths(
      forAllowedTypes: TPPOPDSAcquisitionPath.supportedTypes(),
      allowedRelations: NYPLOPDSAcquisitionRelationSetAll,
      acquisitions: [acquisition]
    )

    // This test may fail without LCP enabled — that's expected for non-DRM builds
    let types = TPPOPDSAcquisitionPath.supportedTypes()
    if types.contains("application/vnd.readium.lcp.license.v1.0+json") {
      XCTAssertFalse(paths.isEmpty, "With LCP enabled, should find path for opds-pub → LCP → epub")
      if let path = paths.first {
        XCTAssertEqual(path.types.last, "application/epub+zip")
      }
    }
    // Without LCP flag, paths will be empty (LCP type not in supportedTypes) — that's acceptable
  }
}
