import XCTest

@testable import Palace

let testFeedUrl = Bundle.init(for: OPDS2CatalogsFeedTests.self)
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
  
  func testBorrowBook() {
    
    let expectation = self.expectation(description: "Books is sent to downloading state")
    
    let notificationObserver = NotificationCenter.default.addObserver(
      forName: .TPPMyBooksDownloadCenterDidChange,
      object: nil,
      queue: nil) { notification in
        expectation.fulfill()
      }
    
    swizzle(selector: #selector(TPPOPDSFeed.swizzledURL_Success(_:shouldResetCache:userTokenIfAvailable:completionHandler:)))
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    myBooksDownloadCenter.startBorrow(for: book, attemptDownload: true)
    
    let borrowedEntry = mockFeed.entries.first as! TPPOPDSEntry
    let expectedDownloadTitle = TPPBook(entry: borrowedEntry)
    
    waitForExpectations(timeout: 30, handler: nil)
    NotificationCenter.default.removeObserver(notificationObserver)
    
    let bookState = mockBookRegistry.state(for: expectedDownloadTitle!.identifier)
    XCTAssertEqual(bookState, TPPBookState.Downloading, "The book should be in the 'Downloading' state.")
  }
  
  func testBorrowBook_withReauthentication() {
    
    let expectation = self.expectation(description: "Books is sent to downloading state")
    
    let notificationObserver = NotificationCenter.default.addObserver(
      forName: .TPPMyBooksDownloadCenterDidChange,
      object: nil,
      queue: nil) { notification in
        expectation.fulfill()
      }
    
    swizzle(selector: #selector(TPPOPDSFeed.swizzledURL_Error(_:shouldResetCache:useTokenIfAvailable:completionHandler:)))
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    myBooksDownloadCenter.startBorrow(for: book, attemptDownload: true)
    
    let borrowedEntry = mockFeed.entries.first as! TPPOPDSEntry
    
    waitForExpectations(timeout: 5, handler: nil)
    NotificationCenter.default.removeObserver(notificationObserver)
    
    XCTAssertTrue(mockReauthenticator.reauthenticationPerformed)
    let bookState = mockBookRegistry.state(for: book.identifier)
    XCTAssertEqual(bookState, TPPBookState.Downloading, "The book should be in the 'Downloading' state.")
  }
  
  private func swizzle(selector: Selector) {
    let aClass: AnyClass? = object_getClass(TPPOPDSFeed.self)
    let originalSelector = #selector(TPPOPDSFeed.withURL(_:shouldResetCache:useTokenIfAvailable:completionHandler:))
    let swizzledSelector = selector
    
    let originalMethod = class_getInstanceMethod(aClass, originalSelector)
    let swizzledMethod = class_getInstanceMethod(TPPOPDSFeed.self, swizzledSelector)
    
    method_exchangeImplementations(originalMethod!, swizzledMethod!)
  }
}

let mockFeed: TPPOPDSFeed = {
  let filePath = Bundle(for: MyBooksDownloadCenterTests.self).path(forResource: "main", ofType: "xml")!
  let data = try! Data(contentsOf: URL(fileURLWithPath: filePath))
  let feedXML = TPPXML(data: data)!
  return TPPOPDSFeed(xml: feedXML)
}()

extension TPPOPDSFeed {
  @objc func swizzledURL_Success(
    _ url: URL,
    shouldResetCache: Bool,
    userTokenIfAvailable: Bool,
    completionHandler: @escaping (TPPOPDSFeed?, [String: Any]?) -> Void) {
    completionHandler(mockFeed, nil)
  }

  @objc func swizzledURL_Error(
    _ url: URL,
    shouldResetCache: Bool,
    useTokenIfAvailable: Bool,
    completionHandler: @escaping (TPPOPDSFeed?, [String: Any]?) -> Void) {
      completionHandler(nil, ["type": TPPProblemDocument.TypeInvalidCredentials])
    }
}
