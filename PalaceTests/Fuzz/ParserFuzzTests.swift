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
    FuzzRunner.fuzz(corpusType: .opds1XML, iterations: 500) { data in
      // Two-stage parse: TPPXML tokenizes, TPPOPDSFeed builds the model.
      let xml = TPPXML(data: data)
      _ = TPPOPDSFeed(xml: xml)
      return ()
    }
  }

  // MARK: - OPDS 2.0 JSON (catalogs feed)

  func testFuzz_OPDS2JSON_NoCrashes() {
    FuzzRunner.fuzz(corpusType: .opds2JSON, iterations: 500) { data in
      _ = try OPDS2CatalogsFeed.fromData(data)
      return ()
    }
  }

  // MARK: - LCP license JSON

  func testFuzz_LCPLicense_NoCrashes() {
    FuzzRunner.fuzz(corpusType: .lcpLicense, iterations: 500) { data in
      // FUZZ-GAP: TPPLCPLicense's only public initializer takes a URL, not
      // Data. Exercise the underlying Codable decode directly — same code
      // path the file-based init uses internally.
      _ = try JSONDecoder().decode(TPPLCPLicense.self, from: data)
      return ()
    }
  }

  // MARK: - Annotations server response JSON

  func testFuzz_AnnotationsResponse_NoCrashes() {
    FuzzRunner.fuzz(corpusType: .annotationsResponse, iterations: 500) { data in
      // FUZZ-GAP: TPPAnnotations response parsing is private to the network
      // layer (annotationID/timeStamp/fromNetworkData are file-private). The
      // public surface decodes the LD+JSON envelope through JSONSerialization
      // and walks the dictionary; reproduce that here as the fuzz target.
      let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      _ = (obj as? [String: Any])?["first"]
      _ = (obj as? [String: Any])?["total"]
      return ()
    }
  }
}
