//
//  AccountManagerTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 10/21/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

class AccountManagerTests: XCTestCase {
  
  private var cancellable: AnyCancellable?
  private let timeout: TimeInterval = 10
  let testCatalogFeed = Bundle.init(for: OPDS2CatalogsFeedTests.self)
    .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!
  
  let networkManager = AppNetworkManager(executor: MockNetworkExecutor())
  lazy var accountManager = AppAccountManager(networkManager: networkManager)
  
  func testLoadCatalogs() {
    let exp = expectation(description: "load catalog test succeeds")
    accountManager.loadCatalogs(url: testCatalogFeed)
    XCTAssertEqual(accountManager.accountSets.count, 2)
    exp.fulfill()
    waitForExpectations(timeout: timeout)
  }
  
  func testLoadAuthDoc() {
    let exp = expectation(description: "network test succeeds")
    accountManager.loadCatalogs(url: testCatalogFeed)
    
    let testAuthDocURL = Bundle.init(for: OPDS2CatalogsFeedTests.self)
      .url(forResource: "lyrasis_reads_authentication_document", withExtension: "json")!

    guard let account = accountManager.accountSets.first!.value.first else {
      XCTFail()
      return
    }
    
    account.authenticationDocumentUrl = testAuthDocURL.absoluteString
    accountManager.loadAuthenticationDocument(for: account) { success in
      XCTAssertTrue(success)
      XCTAssertNotNil(account.authenticationDocument)
      exp.fulfill()
    }
    waitForExpectations(timeout: timeout)
  }
}

fileprivate struct TestError: TPPUserFriendlyError {
  var userFriendlyTitle: String? = "Test Failed"
  var userFriendlyMessage: String? = nil
}

fileprivate class MockNetworkExecutor: NetworkExecutor {
  
  func GET(_ reqURL: URL, completion: @escaping (NYPLResult<Data>) -> Void) {
    guard let data = try? Data(contentsOf: reqURL) else {
      completion(.failure(TestError(), nil))
      return
    }
    
    completion(.success(data, nil))
  }
}
