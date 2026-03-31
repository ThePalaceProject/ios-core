import XCTest
@testable import Palace

class TPPKeychainSwiftTests: XCTestCase {

  func test0() {
    TPPKeychain.sharedKeychain.setObject("foo", forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D")
    XCTAssertEqual(TPPKeychain.sharedKeychain.object(forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D") as? String, "foo")

    TPPKeychain.sharedKeychain.setObject("bar", forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D")
    XCTAssertEqual(TPPKeychain.sharedKeychain.object(forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D") as? String, "bar")

    TPPKeychain.sharedKeychain.setObject("baz", forKey: "7D6F207E-9D04-4EE8-9D96-6E07777376C0")
    XCTAssertEqual(TPPKeychain.sharedKeychain.object(forKey: "7D6F207E-9D04-4EE8-9D96-6E07777376C0") as? String, "baz")

    XCTAssertEqual(TPPKeychain.sharedKeychain.object(forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D") as? String, "bar")

    TPPKeychain.sharedKeychain.removeObject(forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D")
    XCTAssertNil(TPPKeychain.sharedKeychain.object(forKey: "D5AAFADD-E036-4CA6-BBC7-B5962455831D"))

    XCTAssertEqual(TPPKeychain.sharedKeychain.object(forKey: "7D6F207E-9D04-4EE8-9D96-6E07777376C0") as? String, "baz")

    TPPKeychain.sharedKeychain.removeObject(forKey: "7D6F207E-9D04-4EE8-9D96-6E07777376C0")
    XCTAssertNil(TPPKeychain.sharedKeychain.object(forKey: "7D6F207E-9D04-4EE8-9D96-6E07777376C0"))
  }
}
