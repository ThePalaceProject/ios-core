import XCTest
@testable import PalaceKeychain

final class TPPKeychainSwiftTests: XCTestCase {

  private let testKey1 = "TPPKeychainTest_\(UUID().uuidString)"
  private let testKey2 = "TPPKeychainTest_\(UUID().uuidString)"

  override func setUpWithError() throws {
    try super.setUpWithError()
    try KeychainAvailability.skipIfUnavailable()
  }

  override func tearDown() {
    super.tearDown()
    TPPKeychain.shared.removeObject(forKey: testKey1)
    TPPKeychain.shared.removeObject(forKey: testKey2)
  }

  // MARK: - Roundtrip

  func test_setObject_roundtripsStringAndNumber() {
    TPPKeychain.shared.setObject("hello", forKey: testKey1)
    TPPKeychain.shared.setObject(NSNumber(value: 42), forKey: testKey2)

    XCTAssertEqual(TPPKeychain.shared.object(forKey: testKey1) as? String,
                   "hello",
                   "String set-then-get should round-trip unchanged")
    XCTAssertEqual(TPPKeychain.shared.object(forKey: testKey2) as? NSNumber,
                   NSNumber(value: 42),
                   "NSNumber set-then-get should round-trip unchanged")
  }

  func test_setObject_overwritesPreviousValueAndRemoveClearsIt() {
    TPPKeychain.shared.setObject("first", forKey: testKey1)
    TPPKeychain.shared.setObject("second", forKey: testKey1)
    XCTAssertEqual(TPPKeychain.shared.object(forKey: testKey1) as? String,
                   "second",
                   "second setObject must replace, not append or no-op")

    TPPKeychain.shared.removeObject(forKey: testKey1)
    XCTAssertNil(TPPKeychain.shared.object(forKey: testKey1),
                 "remove after overwrite should leave no residue")
  }

  // MARK: - Absence (missing, removed, cross-key)

  func test_keyAbsence_behavesConsistentlyAcrossMissingRemovedAndCrossKey() {
    // Never-written key: get should return nil, remove should be a safe no-op.
    let neverWritten = "never_written_\(UUID().uuidString)"
    XCTAssertNil(TPPKeychain.shared.object(forKey: neverWritten),
                 "never-set key must read back nil")
    TPPKeychain.shared.removeObject(forKey: neverWritten)
    XCTAssertNil(TPPKeychain.shared.object(forKey: neverWritten),
                 "remove-then-get on a never-set key must still be nil")

    // Cross-key: removing one key must not affect siblings.
    TPPKeychain.shared.setObject("value1", forKey: testKey1)
    TPPKeychain.shared.setObject("value2", forKey: testKey2)
    TPPKeychain.shared.removeObject(forKey: testKey1)
    XCTAssertNil(TPPKeychain.shared.object(forKey: testKey1),
                 "removed key should read back nil")
    XCTAssertEqual(TPPKeychain.shared.object(forKey: testKey2) as? String,
                   "value2",
                   "removing testKey1 must not disturb testKey2")
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
        TPPKeychain.shared.setObject("value_\(i)", forKey: key)
        _ = TPPKeychain.shared.object(forKey: key)
        group.leave()
      }
    }

    group.notify(queue: .main) {
      expectation.fulfill()
    }

    waitForExpectations(timeout: 10)
    // After all concurrent writes, the final value should be readable (not corrupted/nil)
    let finalValue = TPPKeychain.shared.object(forKey: testKey1)
    XCTAssertNotNil(finalValue, "After concurrent writes, keychain should have a readable value (not corrupted)")
  }
}
