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
}
