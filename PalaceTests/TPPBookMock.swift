//
//  TPPBookMock.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 8/31/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

// MARK: - DistributorType

enum DistributorType: String {
  case OPDSCatalog = "application/atom+xml;type=entry;profile=opds-catalog"
  case AdobeAdept = "application/vnd.adobe.adept+xml"
  case BearerToken = "application/vnd.librarysimplified.bearer-token+json"
  case EpubZip = "application/epub+zip"
  case Findaway = "application/vnd.librarysimplified.findaway.license+json"
  case OpenAccessAudiobook = "application/audiobook+json"
  case OpenAccessPDF = "application/pdf"
  case FeedbooksAudiobook = "application/audiobook+json;profile=\"http://www.feedbooks.com/audiobooks/access-restriction\""
  case OctetStream = "application/octet-stream"
  case OverdriveAudiobook = "application/vnd.overdrive.circulation.api+json;profile=audiobook"
  case ReadiumLCP = "application/vnd.readium.lcp.license.v1.0+json"
  case PDFLCP = "application/pdf+lcp"
  case AudiobookLCP = "application/audiobook+lcp"
  case AudiobookZip = "application/audiobook+zip"
  case Biblioboard = "application/json"

  static func randomIdentifier() -> String {
    UUID().uuidString
  }
}

// MARK: - TPPBookMocker

enum TPPBookMocker {
  static func mockBook(distributorType: DistributorType) -> TPPBook {
    let configType = distributorType.rawValue

    // Randomly generated values for other fields
    let identifier = DistributorType.randomIdentifier()
    let emptyUrl = URL(string: "http://example.com/\(identifier)")!

    let fakeAcquisition = TPPOPDSAcquisition(
      relation: .generic,
      type: configType,
      hrefURL: emptyUrl,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )

    let fakeBook = TPPBook(
      acquisitions: [fakeAcquisition],
      authors: [TPPBookAuthor(authorName: "Author \(identifier)", relatedBooksURL: nil)],
      categoryStrings: ["Category \(identifier)"],
      distributor: "Distributor \(identifier)",
      identifier: identifier,
      imageURL: emptyUrl,
      imageThumbnailURL: emptyUrl,
      published: Date(),
      publisher: "Publisher \(identifier)",
      subtitle: "Subtitle \(identifier)",
      summary: "Summary \(identifier)",
      title: "Title \(identifier)",
      updated: Date(),
      annotationsURL: emptyUrl,
      analyticsURL: emptyUrl,
      alternateURL: emptyUrl,
      relatedWorksURL: emptyUrl,
      previewLink: fakeAcquisition,
      seriesURL: emptyUrl,
      revokeURL: emptyUrl,
      reportURL: emptyUrl,
      timeTrackingURL: emptyUrl,
      contributors: [:],
      bookDuration: nil,
      imageCache: MockImageCache()
    )

    return fakeBook
  }
}
