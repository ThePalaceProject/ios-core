import XCTest
@testable import Palace

final class TPPKeychainSwiftTests: XCTestCase {

  private let testKey1 = "TPPKeychainTest_\(UUID().uuidString)"
  private let testKey2 = "TPPKeychainTest_\(UUID().uuidString)"

  override func tearDown() {
    super.tearDown()
    TPPKeychain.shared().removeObject(forKey: testKey1)
    TPPKeychain.shared().removeObject(forKey: testKey2)
  }

  // MARK: - Roundtrip

  func test_setAndGet_roundtripsStringValue() {
    TPPKeychain.shared().setObject("hello", forKey: testKey1)
    let result = TPPKeychain.shared().object(forKey: testKey1) as? String
    XCTAssertEqual(result, "hello")
  }

  func test_setAndGet_roundtripsNumberValue() {
    let number = NSNumber(value: 42)
    TPPKeychain.shared().setObject(number, forKey: testKey1)
    let result = TPPKeychain.shared().object(forKey: testKey1) as? NSNumber
    XCTAssertEqual(result, number)
  }

  func test_setObject_overwritesPreviousValue() {
    TPPKeychain.shared().setObject("first", forKey: testKey1)
    TPPKeychain.shared().setObject("second", forKey: testKey1)
    let result = TPPKeychain.shared().object(forKey: testKey1) as? String
    XCTAssertEqual(result, "second")
  }

  // MARK: - Removal

  func test_removeObjectForKey_removesEntry() {
    TPPKeychain.shared().setObject("value", forKey: testKey1)
    TPPKeychain.shared().removeObject(forKey: testKey1)
    let result = TPPKeychain.shared().object(forKey: testKey1)
    XCTAssertNil(result, "Object should be nil after removal")
  }

  func test_removeObjectForKey_doesNotAffectOtherKeys() {
    TPPKeychain.shared().setObject("value1", forKey: testKey1)
    TPPKeychain.shared().setObject("value2", forKey: testKey2)
    TPPKeychain.shared().removeObject(forKey: testKey1)

    XCTAssertNil(TPPKeychain.shared().object(forKey: testKey1))
    XCTAssertEqual(TPPKeychain.shared().object(forKey: testKey2) as? String, "value2")
  }

  func test_removeObjectForKey_nonexistentKey_doesNotCrash() {
    // Should not throw or crash
    TPPKeychain.shared().removeObject(forKey: "nonexistent_key_\(UUID().uuidString)")
  }

  // MARK: - Missing Keys

  func test_objectForKey_missingKey_returnsNil() {
    let result = TPPKeychain.shared().object(forKey: "missing_key_\(UUID().uuidString)")
    XCTAssertNil(result)
  }

  // MARK: - Thread Safety

  func test_concurrentReadsAndWrites_doNotCrash() {
    let expectation = expectation(description: "Concurrent keychain access completes")
    let iterations = 50
    let group = DispatchGroup()

    for i in 0..<iterations {
      group.enter()
      DispatchQueue.global().async {
        let key = self.testKey1
        TPPKeychain.shared().setObject("value_\(i)", forKey: key)
        _ = TPPKeychain.shared().object(forKey: key)
        group.leave()
      }
    }

    group.notify(queue: .main) {
      expectation.fulfill()
    }

    waitForExpectations(timeout: 10)
  }
}
