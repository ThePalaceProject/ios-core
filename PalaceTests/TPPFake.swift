//
//  TPPFake.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/27/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPFake {
  /// Placeholder URL for tests that won't trigger network requests
  private static let placeholderURL = URL(string: "https://test.example.com/placeholder")!
  
  class var genericAcquisition: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: placeholderURL,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var genericAudiobookAcquisition: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .generic,
      type: "application/audiobook+json",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [TPPOPDSIndirectAcquisition](),
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var genericSample: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .sample,
      type: "application/epub+zip",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }

  class var genericAudiobookSample: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .sample,
      type: "application/audiobook+json",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var overdriveWebAudiobookSample: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .preview,
      type: "text/html",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var overdriveAudiobookWaveFile: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .sample,
      type: "audio/x-ms-wma",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var overdriveAudiobookMPEG: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .sample,
      type: "audio/mpeg",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }
  
  class var genericPreview: TPPOPDSAcquisition {
    TPPOPDSAcquisition(
      relation: .preview,
      type: "application/epub+zip",
      hrefURL: URL(string:"https://market.feedbooks.com/item/3877422/preview")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
  }

  class var opdsEntry: TPPOPDSEntry {
    let bundle = Bundle(for: TPPFake.self)
    let url = bundle.url(forResource: "NYPLOPDSAcquisitionPathEntry",
                         withExtension: "xml")!
    let xml = try! TPPXML(data: Data(contentsOf: url))
    let entry = TPPOPDSEntry(xml: xml)
    return entry!
  }

  class var opdsEntryMinimal: TPPOPDSEntry {
    let bundle = Bundle(for: TPPFake.self)
    let url = bundle.url(forResource: "NYPLOPDSAcquisitionPathEntryMinimal",
                         withExtension: "xml")!
    return try! TPPOPDSEntry(xml: TPPXML(data: Data(contentsOf: url)))
  }

  static let validUserProfileJson = """
  {
    "simplified:authorization_identifier": "23333999999915",
    "drm": [
      {
        "drm:vendor": "NYPL",
        "drm:scheme": "http://librarysimplified.org/terms/drm/scheme/ACS",
        "drm:clientToken": "someToken"
      }
    ],
    "links": [
      {
        "href": "https://circulation.librarysimplified.org/NYNYPL/AdobeAuth/devices",
        "rel": "http://librarysimplified.org/terms/drm/rel/devices"
      }
    ],
    "simplified:authorization_expires": "2025-05-01T00:00:00Z",
    "settings": {
      "simplified:synchronize_annotations": true
    }
  }
  """

}
