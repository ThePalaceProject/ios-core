import XCTest
import PalaceBookModel

@testable import Palace

@MainActor
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
        XCTAssertEqual(TPPBookState.unregistered.rawValue, TPPBookState(UnregisteredKey)?.rawValue)
        XCTAssertEqual(TPPBookState.downloadNeeded.rawValue, TPPBookState(DownloadNeededKey)?.rawValue)
        XCTAssertEqual(TPPBookState.downloading.rawValue, TPPBookState(DownloadingKey)?.rawValue)
        XCTAssertEqual(TPPBookState.downloadFailed.rawValue, TPPBookState(DownloadFailedKey)?.rawValue)
        XCTAssertEqual(TPPBookState.downloadSuccessful.rawValue, TPPBookState(DownloadSuccessfulKey)?.rawValue)
        XCTAssertEqual(TPPBookState.holding.rawValue, TPPBookState(HoldingKey)?.rawValue)
        XCTAssertEqual(TPPBookState.used.rawValue, TPPBookState(UsedKey)?.rawValue)
        XCTAssertEqual(TPPBookState.unsupported.rawValue, TPPBookState(UnsupportedKey)?.rawValue)
        XCTAssertNil(TPPBookState("InvalidString"))
    }

    func testAllBookState() {
        // Pins the ordered raw-value contract (formerly asserted via the deleted
        // TPPBookStateHelper.allBookStates()). The wire raw values must stay
        // stable — a reorder or inserted case would change persisted state ints.
        XCTAssertEqual(TPPBookState.allCases.map { $0.rawValue }, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertFalse(TPPBookState.allCases.isEmpty,
                       "allCases should return a non-empty array of states")
    }
}
