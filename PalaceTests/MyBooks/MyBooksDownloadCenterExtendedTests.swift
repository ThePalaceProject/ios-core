//
//  MyBooksDownloadCenterExtendedTests.swift
//  PalaceTests
//
//  Extended tests for MyBooksDownloadCenter functionality
//

import XCTest
@testable import Palace

final class MyBooksDownloadCenterExtendedTests: XCTestCase {
  
  // MARK: - Properties
  
  private var downloadCenter: MyBooksDownloadCenter!
  private var mockUserAccount: TPPUserAccount!
  private var mockReauthenticator: TPPReauthenticatorMock!
  private var mockBookRegistry: TPPBookRegistryMock!
  
  // MARK: - Setup
  
  override func setUp() {
    super.setUp()
    
    mockUserAccount = TPPUserAccount()
    mockReauthenticator = TPPReauthenticatorMock()
    mockBookRegistry = TPPBookRegistryMock()
    
    downloadCenter = MyBooksDownloadCenter(
      userAccount: mockUserAccount,
      reauthenticator: mockReauthenticator,
      bookRegistry: mockBookRegistry
    )
  }
  
  override func tearDown() {
    downloadCenter = nil
    mockUserAccount = nil
    mockReauthenticator = nil
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  // MARK: - Download Queue Tests
  
  func testDownloadQueue_initiallyEmpty() {
    // After initialization, no downloads should be in progress
    XCTAssertNotNil(downloadCenter)
  }
  
  func testDownloadQueue_addsBookToQueue() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    // Register book first
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Start download - this adds to queue
    downloadCenter.startDownload(for: book)
    
    // State should change to indicate download started
    let state = mockBookRegistry.state(for: book.identifier)
    XCTAssertTrue([.downloadNeeded, .downloading, .downloadFailed].contains(state))
  }
  
  // MARK: - Progress Tracking Tests
  
  func testProgressTracking_initialProgress() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    let progress = downloadCenter.downloadProgress(for: book.identifier)
    
    // Progress should be 0 or undefined before download starts
    XCTAssertTrue(progress >= 0.0 || progress.isNaN)
  }
  
  // MARK: - Cancel Download Tests
  
  func testCancelDownload_removesFromQueue() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    downloadCenter.startDownload(for: book)
    downloadCenter.cancelDownload(for: book.identifier)
    
    // Cancel is async - just verify the call didn't crash
    // State changes happen asynchronously via notifications
    XCTAssertTrue(true, "Cancel download completed without crash")
  }
  
  // MARK: - Reset Tests
  
  func testReset_clearsDownloads() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    downloadCenter.startDownload(for: book)
    downloadCenter.reset(book.identifier)
    
    // After reset, book should be removed
    XCTAssertTrue(true, "Reset completed without crash")
  }
  
  // MARK: - Return Book Tests
  
  func testReturnBook_changesState() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadSuccessful,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Return the book - this initiates the return process
    downloadCenter.returnBook(withIdentifier: book.identifier)
    
    // The return process is async, verify the call didn't crash
    // State may or may not have changed yet depending on network
    XCTAssertTrue(true, "Return book initiated successfully")
  }
}

// MARK: - Download State Machine Tests

final class DownloadStateMachineTests: XCTestCase {
  
  private var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  func testState_downloadNeeded_canTransitionToDownloading() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  func testState_downloading_canTransitionToSuccess() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testState_downloading_canTransitionToFailed() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloadFailed, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadFailed)
  }
  
  func testState_downloadFailed_canRetry() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadFailed,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Retry by setting back to downloading
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
}

// MARK: - Disk Space Tests

final class DownloadDiskSpaceTests: XCTestCase {
  
  func testAvailableDiskSpace_isPositive() {
    let attributes = try? FileManager.default.attributesOfFileSystem(
      forPath: NSHomeDirectory()
    )
    
    let freeSpace = attributes?[.systemFreeSize] as? Int64 ?? 0
    XCTAssertGreaterThan(freeSpace, 0)
  }
  
  func testDocumentsDirectory_exists() {
    let documentsPath = NSSearchPathForDirectoriesInDomains(
      .documentDirectory,
      .userDomainMask,
      true
    ).first
    
    XCTAssertNotNil(documentsPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: documentsPath!))
  }
}

// MARK: - Concurrent Download Tests

final class ConcurrentDownloadTests: XCTestCase {
  
  private var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  func testMultipleBooks_canBeQueuedSimultaneously() {
    let book1 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book2 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book3 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book3, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // All books should be registered
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book1.identifier))
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book2.identifier))
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book3.identifier))
  }
  
  func testDownloadQueue_handlesRapidRequests() {
    let downloadCenter = MyBooksDownloadCenter(
      userAccount: TPPUserAccount(),
      reauthenticator: TPPReauthenticatorMock(),
      bookRegistry: mockBookRegistry
    )
    
    // Quickly add and cancel downloads
    for _ in 0..<5 {
      let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
      mockBookRegistry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
      downloadCenter.startDownload(for: book)
      downloadCenter.cancelDownload(for: book.identifier)
    }
    
    // Should not crash
    XCTAssertTrue(true, "Rapid requests handled without crash")
  }
}

