@testable import Palace
import XCTest
#if LCP
import ReadiumLCP
#endif

/// Tests for ReaderService error classification and transparent re-download behavior.
///
/// The re-download flow itself (deleteLocalContent → setState → startDownload → observe → retry)
/// is exercised by the manual reproduce_lcp_mismatch.sh script and covered indirectly through
/// the existing integration test suite. These unit tests focus on the pure logic that can be
/// exercised without UIKit or singleton side-effects.
final class ReaderServiceExpiredLoanTests: XCTestCase {

    // MARK: - Non-LCP / nil

    func testExpiredLoanMessage_nilError_returnsNil() {
        XCTAssertNil(ReaderService.expiredLoanMessage(for: nil))
    }

    func testExpiredLoanMessage_genericNSError_returnsNil() {
        let error = NSError(domain: "test", code: 42)
        XCTAssertNil(ReaderService.expiredLoanMessage(for: error))
    }

    // MARK: - LCP licenseStatus errors (should produce a message)

    #if LCP
    func testExpiredLoanMessage_expiredLicense_returnsNonNilMessage() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 86400)
        let error = LCPError.licenseStatus(.expired(start: start, end: end))
        let message = ReaderService.expiredLoanMessage(for: error)
        XCTAssertNotNil(message, "An expired LCP license should produce a user-facing message")
    }

    func testExpiredLoanMessage_expiredLicense_containsFormattedDate() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 86400)
        let error = LCPError.licenseStatus(.expired(start: start, end: end))
        let message = ReaderService.expiredLoanMessage(for: error) ?? ""
        XCTAssertFalse(message.isEmpty, "Expiry message should not be empty")
    }

    func testExpiredLoanMessage_returnedLicense_returnsNonNilMessage() {
        let error = LCPError.licenseStatus(.returned)
        XCTAssertNotNil(ReaderService.expiredLoanMessage(for: error))
    }

    func testExpiredLoanMessage_revokedLicense_returnsNonNilMessage() {
        let error = LCPError.licenseStatus(.revoked)
        XCTAssertNotNil(ReaderService.expiredLoanMessage(for: error))
    }

    func testExpiredLoanMessage_cancelledLicense_returnsNonNilMessage() {
        let error = LCPError.licenseStatus(.cancelled)
        XCTAssertNotNil(ReaderService.expiredLoanMessage(for: error))
    }

    // MARK: - LCP non-status errors (should NOT produce a message — fall through to re-download)

    func testExpiredLoanMessage_missingPassphrase_returnsNil() {
        XCTAssertNil(ReaderService.expiredLoanMessage(for: LCPError.missingPassphrase),
                     "missingPassphrase is not an expiry — should fall through to transparent re-download")
    }

    func testExpiredLoanMessage_networkError_returnsNil() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertNil(ReaderService.expiredLoanMessage(for: LCPError.network(underlying)),
                     "Network errors are not expiry — should fall through to transparent re-download")
    }

    func testExpiredLoanMessage_licenseIntegrity_returnsNil() {
        XCTAssertNil(ReaderService.expiredLoanMessage(for: LCPError.licenseIntegrity(.licenseSignatureInvalid)),
                     "Integrity errors are not expiry — should fall through to transparent re-download")
    }

    func testExpiredLoanMessage_parsing_returnsNil() {
        let underlying = NSError(domain: "test", code: 0)
        XCTAssertNil(ReaderService.expiredLoanMessage(for: LCPError.parsing(underlying)),
                     "Parsing errors are not expiry — should fall through to transparent re-download")
    }
    #endif
}
