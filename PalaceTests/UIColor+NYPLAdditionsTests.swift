//
//  UIColor+NYPLAdditionsTests.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/28/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import XCTest
@testable import Palace

class UIColor_NYPLAdditionsTests: XCTestCase {
    func testExample() throws {
        let color = UIColor(red: 0.65, green: 0.23, blue: 0.8, alpha: 0.4)

        XCTAssertEqual(color.javascriptHexString, "#A63BCC")
        // Result should always be 7 characters: "#" + 6 hex digits
        XCTAssertEqual(color.javascriptHexString.count, 7,
                       "javascriptHexString should always produce a 7-character #RRGGBB string")
        // Hex string should always start with '#'
        XCTAssertTrue(color.javascriptHexString.hasPrefix("#"),
                      "javascriptHexString should start with '#'")
        // Deterministic: calling twice on same color produces same result
        XCTAssertEqual(color.javascriptHexString, color.javascriptHexString,
                       "javascriptHexString should be deterministic across calls")
    }

}
