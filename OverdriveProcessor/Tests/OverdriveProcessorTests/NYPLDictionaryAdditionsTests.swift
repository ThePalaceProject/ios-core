//
//  NYPLDictionaryAdditionsTests.swift
//  OverdriveProcessorTests
//
//  Created by Ettore Pasquini on 8/13/20.
//  Copyright © 2020 NYPL. All rights reserved.
//

import XCTest

class NYPLDictionaryAdditionsTests: XCTestCase {
  func testFormLowercaseKeys() throws {
    var dict: [String: Any] = [
      "x-Overdrive-ScopE": "OD",
      "Location" : "the Location",
      "location": "Some other location that will be wiped"
    ]
    dict.formLowercaseKeys()
    XCTAssertEqual(dict.count, 2)
    XCTAssert(dict["x-overdrive-scope"] as! String == "OD")
    XCTAssert(dict["location"] as! String == "the Location")

    var dict2: [String: String] = [
      "x-Overdrive-ScopE": "OD",
      "Location" : "the Location",
      "location": "Some other location that will be wiped"
    ]
    dict2.formLowercaseKeys()
    XCTAssertEqual(dict2.count, 2)
    XCTAssert(dict2["x-overdrive-scope"]! == "OD")
    XCTAssert(dict2["location"]! == "the Location")
  }
}
