//
//  NetworkManagerTests.swift
//  PalaceTests
//
//  Created by Maurice Work on 10/18/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

class NetworkManagerTests: XCTestCase {
  
  private var cancellable: AnyCancellable?
  let networkManager = AppNetworkManager(executor: MockNetworkExecutor())
  
  func testAuthDocFetch() {
    let testAuthDocument = Bundle.init(for: OPDS2CatalogsFeedTests.self)
      .url(forResource: "lyrasis_reads_authentication_document", withExtension: "json")!

    let exp = expectation(description: "network test succeeds")
    
    cancellable = networkManager.fetchAuthenticationDocument(url: testAuthDocument.absoluteString)
      .sink { result in
        exp.fulfill()

        switch result {
        case let .success(document):
          XCTAssertTrue(document?.title == "Announcements Testing")
        case let .failure(error):
          XCTFail(error.localizedDescription)
        }
      }
    
    waitForExpectations(timeout: 10)
  }
  
  func testFetchCatalogFeed() {
    let exp = expectation(description: "network test succeeds")
    let testCatalogFeed = Bundle.init(for: OPDS2CatalogsFeedTests.self)
      .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
    
    let testCatalogsExpectedCount = 171
    
    cancellable = networkManager.fetchCatalog(url: testCatalogFeed.absoluteString)
      .sink { result in
        exp.fulfill()
        
        switch result {
        case let .success(feed):
          XCTAssertNotNil(feed)
          XCTAssertEqual(feed?.catalogs.count, testCatalogsExpectedCount)
        case let .failure(error):
          XCTFail(error.localizedDescription)
        }
      }
    
    waitForExpectations(timeout: 10)
  }
}

fileprivate struct TestError: TPPUserFriendlyError {
  var userFriendlyTitle: String? = "Test Failed"
  var userFriendlyMessage: String? = nil
}

fileprivate class MockNetworkExecutor: NetworkExecutor {

  func loadTestAuthDocument(url: URL) -> Data? {
    try? Data(contentsOf: url)
  }

  func GET(_ reqURL: URL, completion: @escaping (NYPLResult<Data>) -> Void) {
    guard let data = loadTestAuthDocument(url: reqURL) else {
      completion(.failure(TestError(), nil))
      return
    }
    
    completion(.success(data, nil))
  }
}
