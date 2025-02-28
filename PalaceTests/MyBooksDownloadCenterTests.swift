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
  
//  func testBorrowBook() {
//    let expectation = self.expectation(description: "Book is sent to downloading state")
//
//    var fulfilled = false
//    NotificationCenter.default.removeObserver(self, name: .TPPMyBooksDownloadCenterDidChange, object: nil)
//
//    var notificationObserver: NSObjectProtocol? // Declare it as optional first
//
//    notificationObserver = NotificationCenter.default.addObserver(
//      forName: .TPPMyBooksDownloadCenterDidChange,
//      object: nil,
//      queue: nil
//    ) { notification in
//      // Ensure fulfill() is only called once
//      guard !fulfilled else { return }
//      fulfilled = true
//      expectation.fulfill()
//
//      if let observer = notificationObserver {
//        NotificationCenter.default.removeObserver(observer) // Remove safely
//      }
//    }
//
//    swizzle(selector: #selector(TPPOPDSFeed.swizzledURL_Success(_:shouldResetCache:userTokenIfAvailable:completionHandler:)))
//
//    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
//    myBooksDownloadCenter.startBorrow(for: book, attemptDownload: true)
//
//    waitForExpectations(timeout: 30, handler: nil)
//  }

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

    // Ensure Reauthentication is Triggered
    XCTAssertTrue(mockReauthenticator.reauthenticationPerformed, "Reauthentication should have been performed.")

    waitForExpectations(timeout: 5, handler: nil)
    NotificationCenter.default.removeObserver(notificationObserver)

    // Give CI/CD some buffer time before assertion
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let bookState = self.mockBookRegistry.state(for: book.identifier)
      XCTAssertTrue([.downloading, .downloadSuccessful].contains(bookState),
                    "The book should be in the 'Downloading' or 'Download Successful' state.")
    }
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
