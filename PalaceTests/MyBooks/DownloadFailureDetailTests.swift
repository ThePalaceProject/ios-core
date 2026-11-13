//
//  The detail line a failed download shows in its alert (PP-5541).
//

import XCTest
@testable import Palace

final class DownloadFailureDetailTests: XCTestCase {

    func testMessage_noError_returnsNilSoTheGenericLineStays() {
        XCTAssertNil(DownloadFailureDetail.message(for: nil))
    }

    func testMessage_adobeErrorWithOriginalCode_showsAdobeNameWithoutURL() {
        let error = NSError(domain: "org.nypl.labs.ADEPTErrorDomain", code: 2,
                            userInfo: ["originalCode": "E_ADEPT_REQUEST_EXPIRED https://acs.example.com/fulfillment"])

        XCTAssertEqual(DownloadFailureDetail.message(for: error),
                       "Error: E_ADEPT_REQUEST_EXPIRED (org.nypl.labs.ADEPTErrorDomain 2)")
    }

    func testMessage_blankOriginalCode_fallsBackToDescription() {
        let error = NSError(domain: "org.nypl.labs.ADEPTErrorDomain", code: 7,
                            userInfo: ["originalCode": "  ",
                                       NSLocalizedDescriptionKey: "Fulfillment failed"])

        XCTAssertEqual(DownloadFailureDetail.message(for: error),
                       "Error: Fulfillment failed (org.nypl.labs.ADEPTErrorDomain 7)")
    }

    func testMessage_urlError_namesDescriptionAndCode() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: "The request timed out."])

        XCTAssertEqual(DownloadFailureDetail.message(for: error),
                       "\(Strings.MyDownloadCenter.downloadFailedUnknownReason)\nError: The request timed out. (NSURLErrorDomain -1001)")
    }

    func testMessage_nonNetworkError_hasNoConnectionAdvice() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "No such file."])

        XCTAssertEqual(DownloadFailureDetail.message(for: error),
                       "Error: No such file. (NSCocoaErrorDomain 260)")
    }

    func testMessage_noStoredDescription_returnsDomainAndCodeOnce() {
        let error = NSError(domain: "NYPLOverdriveDomain", code: 2, userInfo: ["url": "https://example.com"])

        XCTAssertEqual(DownloadFailureDetail.message(for: error), "Error: NYPLOverdriveDomain 2")
    }

    func testMessage_blankDescription_returnsDomainAndCodeOnly() {
        let error = NSError(domain: "Test", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: " \n"])

        XCTAssertEqual(DownloadFailureDetail.message(for: error), "Error: Test 3")
    }
}
