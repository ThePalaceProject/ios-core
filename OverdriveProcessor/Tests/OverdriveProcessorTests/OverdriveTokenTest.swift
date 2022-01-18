import XCTest
@testable import OverdriveProcessor

class OverdriveTokenTest: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testInvalidToken() {
      let emptyData = [String: Any]()
    
      XCTAssertNil(OverdriveToken(json: emptyData))
        
      let invalidTypeData : [String:Any] = ["access_token":0,
                                          "token_type":0,
                                          "expires_in":3600,
                                               "scope":0]
        
      XCTAssertNil(OverdriveToken(json: invalidTypeData))
        
      let missingFieldData : [String:Any] = ["access_token":"gAAAAB44Au1K7B2dvZzcIacUq",
                                               "token_type":"bearer",
                                               "expires_in":3600]
      
      XCTAssertNil(OverdriveToken(json: missingFieldData))
    }
    
    func testValidToken() {
      let validData : [String:Any] = ["access_token":"gAAAAB44Au1K7B2dvZzcIacUq",
                                        "token_type":"bearer",
                                        "expires_in":3600,
                                             "scope":"LIB META AVAIL SRCH PATRON websiteid:{int} puid:{int}"]
      XCTAssertNotNil(OverdriveToken(json: validData))
    }

}
