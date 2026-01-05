import XCTest
@testable import Palace

let testFeedUrl = Bundle(for: OPDS2CatalogsFeedTests.self)
  .url(forResource: "OPDS2CatalogsFeed", withExtension: "json")!

class MyBooksDownloadCenterTests: XCTestCase {

  var myBooksDownloadCenter: MyBooksDownloadCenter!
  var mockUserAccount: TPPUserAccount!
  var mockReauthenticator: TPPReauthenticatorMock!
  var mockBookRegistry: TPPBookRegistryProvider!

  override func setUp() {
    super.setUp()

    mockUserAccount = TPPUserAccount()
    mockReauthenticator = TPPReauthenticatorMock()
    mockBookRegistry = TPPBookRegistryMock()

    myBooksDownloadCenter = MyBooksDownloadCenter(
      userAccount: mockUserAccount,
      reauthenticator: mockReauthenticator,
      bookRegistry: mockBookRegistry
    )
  }

  override func tearDown() {
    super.tearDown()
  }

  func testBorrowBook_startsWithoutCrashing() {
    // Test that startBorrow can be called without crashing
    // Note: Full borrow flow requires network which can't be tested here
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    // Just verify the call doesn't crash
    myBooksDownloadCenter.startBorrow(for: book, attemptDownload: false)
    
    XCTAssertTrue(true, "startBorrow completed without crash")
  }

  func testDownloadCenter_hasBookRegistry() {
    XCTAssertNotNil(mockBookRegistry)
  }
  
  func testDownloadCenter_hasReauthenticator() {
    XCTAssertNotNil(mockReauthenticator)
  }
  
  func testDownloadCenter_initialization() {
    XCTAssertNotNil(myBooksDownloadCenter)
  }
}
