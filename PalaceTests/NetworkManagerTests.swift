//
//  NetworkManagerTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 6/20/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

class MockNetworkManager: NetworkManager {
  var startDownloadAction: () -> Void = {}
  var startBorrowAction: () -> Void = {}
  var downloadTaskAdded: () -> Void = {}

  override func startDownload(for book: TPPBook) {
    super.startDownload(for: book)
    startDownloadAction()
  }
  
  override func startBorrowForBook(
    _ book: TPPBook,
    attemptDownload shouldAttemptDownload: Bool,
    borrowCompletion: (() -> Void)?
  ) {
    startBorrowAction()
  }
  
  override func addDownloadTask(with request: URLRequest, book: TPPBook) {
    super.addDownloadTask(with: request, book: book)
    downloadTaskAdded()
  }
}

class NetworkManagerTests: XCTestCase {
  
  var networkManager: MockNetworkManager!

  var book: TPPBook {
    TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Tractatus",
      "categories": ["some cat"],
      "id": "123",
      "updated": "2020-10-06T17:13:51Z"]
    )!
  }
  
  override func setUp() {
    super.setUp()
    networkManager = MockNetworkManager()
  }
  
  override func tearDown() {
    networkManager = nil
    super.tearDown()
  }
  
  // MARK: - BooksDownloadManager Tests
  
  func testStartDownload() {
    let expectation = XCTestExpectation(description: "Download action invoked")
    
    networkManager.startDownloadAction = {
      expectation.fulfill()
    }

    networkManager.startDownload(for: book)
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testStartDownloadBook_Unregistered() {
    let expectation = XCTestExpectation(description: "Unregistered book registered and set to download")
    
    networkManager.startBorrowAction = {
      let bookState = TPPBookRegistry.shared.state(for: self.book.identifier)
      XCTAssertTrue(bookState == .DownloadNeeded)
      expectation.fulfill()
    }
    
    TPPBookRegistry.shared.setState(.Unregistered, for: book.identifier)
    networkManager.startDownload(for: book)
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testStartDownloadBook_Holding() {
    let expectation = XCTestExpectation(description: "Holding book set to download")

    networkManager.startBorrowAction = {
      let bookState = TPPBookRegistry.shared.state(for: self.book.identifier)
      XCTAssertTrue(bookState == .DownloadNeeded)
      expectation.fulfill()
    }
    
    TPPBookRegistry.shared.setState(.Holding, for: book.identifier)
    networkManager.startDownload(for: book)
    
    wait(for: [expectation], timeout: 1.0)
  }
  
  func testStartDownloadBook_DownloadNeeded() {
    let expectation = XCTestExpectation(description: "DownloadNeeded carried forwards")
    
    networkManager.downloadTaskAdded = {
      let bookState = TPPBookRegistry.shared.state(for: self.book.identifier)
      XCTAssertTrue(bookState == .Downloading)
      expectation.fulfill()
    }
    
    TPPBookRegistry.shared.addBook(book, state: .DownloadNeeded)
    networkManager.startDownload(for: book)
    
    wait(for: [expectation], timeout: 1.0)
  }

  func testPauseDownload() {
    let downloadTask = MockDownloadTask()
    
    networkManager.bookIdentifierToDownloadTask[book.identifier] = downloadTask
    
    networkManager.pauseDownload(for: book)
    
    XCTAssertTrue(downloadTask.state == .suspended)
  }

  func testCancelDownload() {
    let downloadTask = MockDownloadTask()
    networkManager.bookIdentifierToDownloadTask[book.identifier] = downloadTask
    
    networkManager.cancelDownload(for: book)
    
    XCTAssertTrue(downloadTask.state == .canceling)
    XCTAssertNil(networkManager.bookIdentifierToDownloadTask[book.identifier])
    XCTAssertNil(networkManager.bookIdentifierToDownloadInfo[book.identifier])
    XCTAssertNil(networkManager.taskIdentifierToBook[downloadTask.taskIdentifier])
  }
  
  func testResumeDownload() {
    let downloadTask = MockDownloadTask()
    networkManager.bookIdentifierToDownloadTask[book.identifier] = downloadTask
    networkManager.resumeDownload(for: book)
    
    XCTAssertTrue(downloadTask.state == .running)
  }
  
  // MARK: - URLSessionTaskDelegate Tests
  
  func testURLSessionDidReceiveChallenge() {
  }
  
  func testURLSessionWillPerformHTTPRedirection() {
  }
  
  func testURLSessionDidCompleteWithError() {
  }
}

class MockDownloadTask: URLSessionDownloadTask {
  typealias CompletionHandler = (URL?, URLResponse?, Error?) -> Void
  
  private let completionHandler: CompletionHandler?
  
  init(completionHandler: CompletionHandler? = nil) {
    self.completionHandler = completionHandler
  }
  
  override func resume() {
    let fileURL = URL(fileURLWithPath: "/path/to/downloaded/file")
    let response = URLResponse(url: fileURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    completionHandler?(fileURL, response, nil)
  }
  
  override func cancel() {}
}
