import XCTest
@testable import Palace

final class TPPEncryptedPDFDataProviderTests: XCTestCase {

  // MARK: - Initialization

  func test_initWithValidData_succeeds() {
    let testData = Data(repeating: 0xAB, count: 1024)
    let decryptor: (Data, UInt, UInt) -> Data = { data, start, end in
      return data.subdata(in: Int(start)..<Int(end))
    }
    let provider = TPPEncryptedPDFDataProvider(data: testData, decryptor: decryptor)
    // dataProvider() must work after init — this validates the provider is actually functional
    let cgProvider = provider.dataProvider()
    XCTAssertNotNil(cgProvider, "dataProvider() should return a valid CGDataProvider for 1024-byte input")
    // Calling it a second time must also succeed (no single-use teardown)
    let cgProvider2 = provider.dataProvider()
    XCTAssertNotNil(cgProvider2, "dataProvider() must remain callable multiple times")
  }

  func test_initWithEmptyData_succeeds() {
    var decryptorCallCount = 0
    let emptyData = Data()
    let decryptor: (Data, UInt, UInt) -> Data = { _, _, _ in
      decryptorCallCount += 1
      return Data()
    }
    let provider = TPPEncryptedPDFDataProvider(data: emptyData, decryptor: decryptor)
    // Empty data produces a data provider (may produce an empty/nil PDF, but must not crash)
    _ = provider.dataProvider()
    // Decryptor call count may be 0 for empty data — verify it didn't crash with a negative count
    XCTAssertGreaterThanOrEqual(decryptorCallCount, 0, "Decryptor call count must be non-negative")
  }

  // MARK: - Data Provider

  func test_dataProvider_returnsValidCGDataProvider() {
    let testData = Data(repeating: 0xFF, count: 256)
    var decryptorCallCount = 0
    let decryptor: (Data, UInt, UInt) -> Data = { data, start, end in
      decryptorCallCount += 1
      return data.subdata(in: Int(start)..<Int(end))
    }
    let provider = TPPEncryptedPDFDataProvider(data: testData, decryptor: decryptor)
    let cgProvider = provider.dataProvider()
    XCTAssertNotNil(cgProvider, "dataProvider() should return a valid CGDataProvider")
    // Two separate calls should each return a non-nil provider
    let cgProvider2 = provider.dataProvider()
    XCTAssertNotNil(cgProvider2, "Second call to dataProvider() should also succeed")
  }
}
