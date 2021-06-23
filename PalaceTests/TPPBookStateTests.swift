import XCTest

@testable import Palace

class TPPBookStateTests: XCTestCase {
    
    func testInitWithString() {
      XCTAssertEqual(TPPBookState.Unregistered, TPPBookState.init(UnregisteredKey))
      XCTAssertEqual(TPPBookState.DownloadNeeded, TPPBookState.init(DownloadNeededKey))
      XCTAssertEqual(TPPBookState.Downloading, TPPBookState.init(DownloadingKey))
      XCTAssertEqual(TPPBookState.DownloadFailed, TPPBookState.init(DownloadFailedKey))
      XCTAssertEqual(TPPBookState.DownloadSuccessful, TPPBookState.init(DownloadSuccessfulKey))
      XCTAssertEqual(TPPBookState.Holding, TPPBookState.init(HoldingKey))
      XCTAssertEqual(TPPBookState.Used, TPPBookState.init(UsedKey))
      XCTAssertEqual(TPPBookState.Unsupported, TPPBookState.init(UnsupportedKey))
      XCTAssertEqual(nil, TPPBookState.init("InvalidKey"))
    }
    
    func testStringValue() {
      XCTAssertEqual(TPPBookState.Unregistered.stringValue(), UnregisteredKey)
      XCTAssertEqual(TPPBookState.DownloadNeeded.stringValue(), DownloadNeededKey)
      XCTAssertEqual(TPPBookState.Downloading.stringValue(), DownloadingKey)
      XCTAssertEqual(TPPBookState.DownloadFailed.stringValue(), DownloadFailedKey)
      XCTAssertEqual(TPPBookState.DownloadSuccessful.stringValue(), DownloadSuccessfulKey)
      XCTAssertEqual(TPPBookState.Holding.stringValue(), HoldingKey)
      XCTAssertEqual(TPPBookState.Used.stringValue(), UsedKey)
      XCTAssertEqual(TPPBookState.Unsupported.stringValue(), UnsupportedKey)
    }
    
    func testBookStateFromString() {
      XCTAssertEqual(TPPBookState.Unregistered.rawValue, TPPBookStateHelper.bookState(fromString: UnregisteredKey)?.intValue)
      XCTAssertEqual(TPPBookState.DownloadNeeded.rawValue, TPPBookStateHelper.bookState(fromString: DownloadNeededKey)?.intValue)
      XCTAssertEqual(TPPBookState.Downloading.rawValue, TPPBookStateHelper.bookState(fromString: DownloadingKey)?.intValue)
      XCTAssertEqual(TPPBookState.DownloadFailed.rawValue, TPPBookStateHelper.bookState(fromString: DownloadFailedKey)?.intValue)
      XCTAssertEqual(TPPBookState.DownloadSuccessful.rawValue, TPPBookStateHelper.bookState(fromString: DownloadSuccessfulKey)?.intValue)
      XCTAssertEqual(TPPBookState.Holding.rawValue, TPPBookStateHelper.bookState(fromString: HoldingKey)?.intValue)
      XCTAssertEqual(TPPBookState.Used.rawValue, TPPBookStateHelper.bookState(fromString: UsedKey)?.intValue)
      XCTAssertEqual(TPPBookState.Unsupported.rawValue, TPPBookStateHelper.bookState(fromString: UnsupportedKey)?.intValue)
      XCTAssertNil(TPPBookStateHelper.bookState(fromString: "InvalidString"))
    }
    
    func testAllBookState() {
        XCTAssertEqual(TPPBookStateHelper.allBookStates(), TPPBookState.allCases.map{ $0.rawValue })
    }
}
