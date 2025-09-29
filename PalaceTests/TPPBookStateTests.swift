import XCTest

@testable import Palace

class TPPBookStateTests: XCTestCase {
  func testInitWithString() {
    XCTAssertEqual(TPPBookState.unregistered, TPPBookState(UnregisteredKey))
    XCTAssertEqual(TPPBookState.downloadNeeded, TPPBookState(DownloadNeededKey))
    XCTAssertEqual(TPPBookState.downloading, TPPBookState(DownloadingKey))
    XCTAssertEqual(TPPBookState.downloadFailed, TPPBookState(DownloadFailedKey))
    XCTAssertEqual(TPPBookState.downloadSuccessful, TPPBookState(DownloadSuccessfulKey))
    XCTAssertEqual(TPPBookState.holding, TPPBookState(HoldingKey))
    XCTAssertEqual(TPPBookState.used, TPPBookState(UsedKey))
    XCTAssertEqual(TPPBookState.unsupported, TPPBookState(UnsupportedKey))
    XCTAssertEqual(nil, TPPBookState("InvalidKey"))
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
    XCTAssertEqual(
      TPPBookState.unregistered.rawValue,
      TPPBookStateHelper.bookState(fromString: UnregisteredKey)?.intValue
    )
    XCTAssertEqual(
      TPPBookState.downloadNeeded.rawValue,
      TPPBookStateHelper.bookState(fromString: DownloadNeededKey)?.intValue
    )
    XCTAssertEqual(
      TPPBookState.downloading.rawValue,
      TPPBookStateHelper.bookState(fromString: DownloadingKey)?.intValue
    )
    XCTAssertEqual(
      TPPBookState.downloadFailed.rawValue,
      TPPBookStateHelper.bookState(fromString: DownloadFailedKey)?.intValue
    )
    XCTAssertEqual(
      TPPBookState.downloadSuccessful.rawValue,
      TPPBookStateHelper.bookState(fromString: DownloadSuccessfulKey)?.intValue
    )
    XCTAssertEqual(TPPBookState.holding.rawValue, TPPBookStateHelper.bookState(fromString: HoldingKey)?.intValue)
    XCTAssertEqual(TPPBookState.used.rawValue, TPPBookStateHelper.bookState(fromString: UsedKey)?.intValue)
    XCTAssertEqual(
      TPPBookState.unsupported.rawValue,
      TPPBookStateHelper.bookState(fromString: UnsupportedKey)?.intValue
    )
    XCTAssertNil(TPPBookStateHelper.bookState(fromString: "InvalidString"))
  }

  func testAllBookState() {
    XCTAssertEqual(TPPBookStateHelper.allBookStates(), TPPBookState.allCases.map(\.rawValue))
  }
}
