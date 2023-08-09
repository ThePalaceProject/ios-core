import XCTest

import OverdriveProcessor
@testable import Palace

class MyBooksDownloadCenterTests: XCTestCase {
  func testDeleteLocalContent() {
    let fileManager = FileManager.default
    let emptyUrl = URL.init(fileURLWithPath: "")

    // Setup dummy values for fake books per book type
    let configs = [
      [
        "identifier": "fakeEpub",
        "type": "application/epub+zip",
      ],
      // It looks like audiobooks are handled very differently
      // [
      //   "identifier": "fakeAudiobook",
      //   "type": "application/audiobook+json",
      // ],
      [
        "identifier": "fakePdf",
        "type": "application/pdf",
      ]
    ]
    for config in configs {
      // Create fake books and relevant structures required to invoke 
      let fakeAcquisition = TPPOPDSAcquisition.init(
        relation: .generic,
        type: config["type"]!,
        hrefURL: emptyUrl,
        indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
        availability: TPPOPDSAcquisitionAvailabilityUnlimited.init()
      )
      let fakeBook = TPPBook(
        acquisitions: [fakeAcquisition],
        authors: [],
        categoryStrings: [String](),
        distributor: "",
        identifier: config["identifier"]!,
        imageURL: emptyUrl,
        imageThumbnailURL: emptyUrl,
        published: Date.init(),
        publisher: "",
        subtitle: "",
        summary: "",
        title: "",
        updated: Date.init(),
        annotationsURL: emptyUrl,
        analyticsURL: emptyUrl,
        alternateURL: emptyUrl,
        relatedWorksURL: emptyUrl,
        previewLink: fakeAcquisition,
        seriesURL: emptyUrl,
        revokeURL: emptyUrl,
        reportURL: emptyUrl,
        timeTrackingURL: emptyUrl,
        contributors: [:]
      )
            
      // Calculate target filepath to use as "book location"
      let bookUrl = MyBooksDownloadCenter.shared.fileUrl(for: fakeBook.identifier)

      // Create dummy book file at path
      fileManager.createFile(atPath: bookUrl!.path, contents: "Hello world!".data(using: .utf8), attributes: [FileAttributeKey : Any]())

      // Register fake book with registry
      TPPBookRegistry.shared.addBook(
        fakeBook,
        location: TPPBookLocation(locationString: bookUrl!.path, renderer: ""),
        state: .DownloadSuccessful,
        fulfillmentId: "",
        readiumBookmarks: [],
        genericBookmarks: []
      )
      
      // Perform file deletion test
      XCTAssert(fileManager.fileExists(atPath: bookUrl!.path))
      MyBooksDownloadCenter.shared.deleteLocalContent(for: fakeBook.identifier)
      XCTAssert(!fileManager.fileExists(atPath: bookUrl!.path))
    }
  }

  func testDownloadedContentType() {
    let acquisitionsDictionaries = TPPFake.opdsEntry.acquisitions.map {
      $0.dictionaryRepresentation()
    }
    let optBook = TPPBook(dictionary: [
      "acquisitions": acquisitionsDictionaries,
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z",
      "distributor": OverdriveDistributorKey])
    XCTAssertNotNil(optBook)
    let book = optBook!

    for contentType in TPPOPDSAcquisitionPath.supportedTypes() {
      XCTAssert(book.canCompleteDownload(withContentType: contentType))
    }

    XCTAssert(book.canCompleteDownload(withContentType: "application/json"))
  }
}
