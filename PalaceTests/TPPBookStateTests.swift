import XCTest

@testable import Palace

class TPPBookStateTests: XCTestCase {
    
    func testInitWithString() {
      XCTAssertEqual(TPPBookState.unregistered, TPPBookState.init(UnregisteredKey))
      XCTAssertEqual(TPPBookState.downloadNeeded, TPPBookState.init(DownloadNeededKey))
      XCTAssertEqual(TPPBookState.downloading, TPPBookState.init(DownloadingKey))
      XCTAssertEqual(TPPBookState.downloadFailed, TPPBookState.init(DownloadFailedKey))
      XCTAssertEqual(TPPBookState.downloadSuccessful, TPPBookState.init(DownloadSuccessfulKey))
      XCTAssertEqual(TPPBookState.holding, TPPBookState.init(HoldingKey))
      XCTAssertEqual(TPPBookState.used, TPPBookState.init(UsedKey))
      XCTAssertEqual(TPPBookState.unsupported, TPPBookState.init(UnsupportedKey))
      XCTAssertEqual(nil, TPPBookState.init("InvalidKey"))
    }
    
    func testStringValue() {
      XCTAssertEqual(TPPBookState.unregistered.stringValue(), UnregisteredKey)
      XCTAssertEqual(TPPBookState.downloadNeeded.stringValue(), DownloadNeededKey)
      XCTAssertEqual(TPPBookState.downloading.stringValue(), DownloadingKey)
      XCTAssertEqual(TPPBookState.downloadFailed.stringValue(), DownloadFailedKey)
      XCTAssertEqual(TPPBookState.downloadSuccessful.stringValue(), DownloadSuccessfulKey)
      XCTAssertEqual(TPPBookState.holding.stringValue(), HoldingKey)
      XCTAssertEqual(TPPBookState.used.stringValue(), UsedKey)
      XCTAssertEqual(TPPBookState.unsupported.stringValue(), UnsupportedKey)
    }
    
    func testBookStateFromString() {
      XCTAssertEqual(TPPBookState.unregistered.rawValue, TPPBookStateHelper.bookState(fromString: UnregisteredKey)?.intValue)
      XCTAssertEqual(TPPBookState.downloadNeeded.rawValue, TPPBookStateHelper.bookState(fromString: DownloadNeededKey)?.intValue)
      XCTAssertEqual(TPPBookState.downloading.rawValue, TPPBookStateHelper.bookState(fromString: DownloadingKey)?.intValue)
      XCTAssertEqual(TPPBookState.downloadFailed.rawValue, TPPBookStateHelper.bookState(fromString: DownloadFailedKey)?.intValue)
      XCTAssertEqual(TPPBookState.downloadSuccessful.rawValue, TPPBookStateHelper.bookState(fromString: DownloadSuccessfulKey)?.intValue)
      XCTAssertEqual(TPPBookState.holding.rawValue, TPPBookStateHelper.bookState(fromString: HoldingKey)?.intValue)
      XCTAssertEqual(TPPBookState.used.rawValue, TPPBookStateHelper.bookState(fromString: UsedKey)?.intValue)
      XCTAssertEqual(TPPBookState.unsupported.rawValue, TPPBookStateHelper.bookState(fromString: UnsupportedKey)?.intValue)
      XCTAssertNil(TPPBookStateHelper.bookState(fromString: "InvalidString"))
    }
    
    func testAllBookState() {
        XCTAssertEqual(TPPBookStateHelper.allBookStates(), TPPBookState.allCases.map{ $0.rawValue })
    }
}
