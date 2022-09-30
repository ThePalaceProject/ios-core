//
//  ObfuscatorTests.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 9/30/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

class ObfuscatorTests: XCTestCase {
  func testObfuscator() {
    let testString = "TestObfuscationString"
    let obfuscator = Obfuscator()
    let obfuscatedString = obfuscator.bytesByObfuscatingString(string: testString)
    XCTAssertFalse(obfuscatedString.isEmpty)
    let deobfuscatedString = obfuscator.reveal(key: obfuscatedString)
    XCTAssertEqual(testString, deobfuscatedString)
  }
}
