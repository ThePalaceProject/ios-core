//
//  ParserFuzzTests.swift
//  PalaceTests
//
//  Corpus-based fuzz tests for Palace's in-process parsers. Errors thrown
//  by parsers are expected — only crashes/hangs constitute a failure.
//
//  Runtime budget: ~500 mutated inputs per parser, < 30s per test on the
//  iPhone simulator.
//

import XCTest
@testable import Palace

final class ParserFuzzTests: XCTestCase {

  // MARK: - OPDS 1.x XML

  func testFuzz_OPDS1XML_NoCrashes() {
    var iterationsCompleted = 0
    FuzzRunner.fuzz(corpusType: .opds1XML, iterations: 500) { data in
      // Two-stage parse: TPPXML tokenizes, TPPOPDSFeed builds the model.
      let xml = TPPXML(data: data)
      _ = TPPOPDSFeed(xml: xml)
      iterationsCompleted += 1
      return ()
    }
    // If we reach here, no crash occurred. Verify at least one iteration ran.
    XCTAssertGreaterThan(iterationsCompleted, 0, "Fuzz runner must execute at least one iteration")
  }

  // MARK: - OPDS 2.0 JSON (catalogs feed)

  func testFuzz_OPDS2JSON_NoCrashes() {
    var iterationsCompleted = 0
    FuzzRunner.fuzz(corpusType: .opds2JSON, iterations: 500) { data in
      _ = try OPDS2CatalogsFeed.fromData(data)
      iterationsCompleted += 1
      return ()
    }
    XCTAssertGreaterThan(iterationsCompleted, 0, "Fuzz runner must execute at least one iteration")
    // Parsing errors are expected for mutated data; only crashes fail this test
    XCTAssertLessThanOrEqual(iterationsCompleted, 500, "Iterations must not exceed requested count")
  }

  // MARK: - LCP license JSON

  func testFuzz_LCPLicense_NoCrashes() {
    var iterationsCompleted = 0
    FuzzRunner.fuzz(corpusType: .lcpLicense, iterations: 500) { data in
      // FUZZ-GAP: TPPLCPLicense's only public initializer takes a URL, not
      // Data. Exercise the underlying Codable decode directly — same code
      // path the file-based init uses internally.
      _ = try JSONDecoder().decode(TPPLCPLicense.self, from: data)
      iterationsCompleted += 1
      return ()
    }
    // With 2 corpus seeds × 500 iterations = up to 1000 calls; most will throw
    XCTAssertGreaterThan(iterationsCompleted, 0, "Fuzz runner must execute at least one iteration")
  }

  // MARK: - Annotations server response JSON

  func testFuzz_AnnotationsResponse_NoCrashes() {
    let fakeAcq = TPPOPDSAcquisition(
      relation: .generic,
      type: "application/epub+zip",
      hrefURL: URL(string: "http://example.com/fuzz")!,
      indirectAcquisitions: [],
      availability: TPPOPDSAcquisitionAvailabilityUnlimited()
    )
    let fakeBook = TPPBook(
      acquisitions: [fakeAcq], authors: [], categoryStrings: [],
      distributor: "", identifier: "fuzz-test-book", imageURL: nil,
      imageThumbnailURL: nil, published: Date(), publisher: "",
      subtitle: "", summary: "", title: "Fuzz Test Book", updated: Date(),
      annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
      relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
      revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
      contributors: [:], bookDuration: nil,
      imageCache: MockImageCache()
    )
    var iterationsCompleted = 0
    FuzzRunner.fuzz(corpusType: .annotationsResponse, iterations: 500) { data in
      // Exercise the real Palace parsing chain:
      // 1. Envelope parsing (first.items extraction)
      // 2. annotationID extraction
      // 3. timeStamp extraction
      // 4. TPPBookmarkFactory.make(fromServerAnnotation:) for each item
      if let items = TPPAnnotations.parseAnnotationItems(fromData: data) {
        for item in items {
          // Exercise the factory that converts server JSON → domain bookmarks.
          // nil result is expected for mutated data; only crashes fail.
          _ = TPPBookmarkFactory.make(fromServerAnnotation: item,
                                       annotationType: .bookmark,
                                       book: fakeBook)
        }
      }
      // Also exercise the POST-response extractors
      _ = TPPAnnotations.annotationID(fromNetworkData: data)
      _ = TPPAnnotations.timeStamp(fromNetworkData: data)
      iterationsCompleted += 1
      return ()
    }
    XCTAssertGreaterThan(iterationsCompleted, 0, "Fuzz runner must execute at least one iteration")
  }
}
