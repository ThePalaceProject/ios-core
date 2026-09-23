#if canImport(MessageUI)
import XCTest
@testable import TriageBotCore
@testable import TriageBotIOS

/// PP-4808 — the EmailGatewayError → SubmissionFailure mapping. iOS/MessageUI
/// gated (EmailGatewayError only exists where MessageUI imports), so this runs
/// on the CI simulator, not under macOS `swift test`. Every case must map, and
/// only `.userCancelled` may be a non-failure.
final class EmailGatewayFailureMappingTests: XCTestCase {

    func testUserCancelled_mapsToUserCancelled() {
        XCTAssertEqual(EmailGatewayError.userCancelled.asSubmissionFailure, .userCancelled)
    }

    func testMailUnavailable_mapsToTransportFailure() {
        guard case .transport = EmailGatewayError.mailUnavailable.asSubmissionFailure else {
            return XCTFail("mailUnavailable must be a transport failure, not a silent cancel")
        }
    }

    func testNoPresenter_mapsToTransportFailure() {
        guard case .transport = EmailGatewayError.noPresenter.asSubmissionFailure else {
            return XCTFail("noPresenter must be a transport failure")
        }
    }

    func testComposerFailed_mapsToTransportFailure() {
        guard case .transport(let detail) = EmailGatewayError.composerFailed.asSubmissionFailure else {
            return XCTFail("composerFailed must be a transport failure")
        }
        XCTAssertFalse(detail.isEmpty, "Transport detail must carry something for Copy details")
    }
}
#endif
