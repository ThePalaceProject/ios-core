import XCTest
@testable import OverdriveProcessor

class NYPLOAuth2ErrorTests: XCTestCase {

  func testOAuth2ErrorDecoding() throws {
    let errorString = """
      {"error":"invalid_grant","error_description":"Invalid resource owner password credential."}
      """
    let errorData = errorString.data(using: .utf8)!

    guard let oauthError = try? NYPLOAuth2Error.fromData(errorData) else {
      XCTFail("unable to parse valid error")
      return
    }

    XCTAssertEqual(oauthError.errorCode, NYPLOAuth2ErrorCode.invalidGrant)
    XCTAssertEqual(oauthError.errorDescription, "Invalid resource owner password credential.")
  }
}
